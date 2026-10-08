import UIKit
import AVKit
import SwiftUI

/// 驱动画中画（Picture in Picture）窗口并在其中以自绘画面实时显示各项功耗与温度指标
@MainActor
@Observable
final class PiPManager {
    static let shared = PiPManager()

    var isActive: Bool { isPiPActive }
    private(set) var isPiPActive: Bool = false {
        didSet {
            onStateChanged?(isPiPActive)
        }
    }

    var onStateChanged: ((Bool) -> Void)?

 

    private var wantsPiP = false

    private var pipController: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipSourceView: UIView?
    /// AVKit's delegate protocols are not main-actor annotated, so this project's
    /// (main-actor by default) methods cannot witness them. A separate object holds
    /// that conformance and forwards to the manager — see `Proxy`.
    private var proxy: Proxy?
    /// The window's refresh and the wait for the layer to become drawable are tasks
    /// rather than `Timer`s: a timer's closure is `@Sendable`, so under
    /// main-actor-by-default isolation it could not call a method here without an
    /// actor hop.
    private var frameTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private weak var monitor: PowerMonitor?

    // private let canvasSize = CGSize(width: 640, height: 360)
    // private let outputSize = CGSize(width: 1280, height: 720)
    private let canvasSize = CGSize(width: 640, height: 240)
    private let outputSize = CGSize(width: 1280, height: 480)

    private init() {
    }

    /// 配置背景播放音频 session，使画中画在后台和退出 app 时能持续运行
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 在某些环境或模拟器可能抛出异常，忽略
        }
    }

    /// 关联 PowerMonitor 并准备画中画控制器
    func setup(with monitor: PowerMonitor, in containerView: UIView) {
        self.monitor = monitor

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("[PiPManager] PiP is not supported on this device")
            return
        }

        if pipController != nil {
            return
        }

        configureAudioSession()

        // 整个进程只在此处建一次图层与控制器,调用方(锚点视图)却会在每次重建时
        // 再调一次,所以视图要就地复用:多出来的宿主视图会各自挂一份黑底,并让
        // AVKit 在窗口关闭后仍在 inline 位置看到一个可自动拉起的来源。
        if let existing = pipSourceView {
            existing.removeFromSuperview()
            existing.frame = containerView.bounds
            containerView.addSubview(existing)
            return
        }

        let layer = AVSampleBufferDisplayLayer()

        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor

        let sourceView = UIView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 36)
        )

        sourceView.backgroundColor = .black
        sourceView.alpha = 0.01

        layer.frame = sourceView.bounds
        sourceView.layer.addSublayer(layer)

        containerView.addSubview(sourceView)

        self.pipSourceView = sourceView
        self.displayLayer = layer

        // 配置时间基准以确保 DisplayLayer 正常驱动帧播放
        var timebase: CMTimebase?
        let timebaseStatus = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if timebaseStatus == noErr, let tb = timebase {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            CMTimebaseSetTime(tb, time: now)
            CMTimebaseSetRate(tb, rate: 1.0)
            layer.controlTimebase = tb
        }

        self.displayLayer = layer

        let proxy = Proxy(owner: self)
        self.proxy = proxy

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: proxy
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = proxy
        // 代价很大,别打开:图层常驻视图层级且每秒都有新帧,所以它在 AVKit 眼里
        // 永远"正在播放",开着这个开关等于让 iOS 每次退到后台都自行拉起窗口 ——
        // 手动关掉再回主屏,窗口就自己回来了,而用户的意思恰恰相反。窗口只能由
        // 按钮打开。
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        // 关掉了系统那一条路径,用户点关闭时还剩下 `didStop`,由它清掉 `wantsPiP`。
        controller.requiresLinearPlayback = true
        self.pipController = controller

        // 预热并喂一帧，使 isPictureInPicturePossible 尽快就绪
        renderCurrentSnapshot()
    }

    func togglePiP() {
        // 以"意愿"判断,不以窗口状态判断:重试期间窗口尚未打开,而用户关闭窗口时
        // `isPiPActive` 也已经归假,两种情况都必须能反转。
        if wantsPiP {
            stopPiP()
        } else {
            startPiP()
        }
    }

    func startPiP() {
        guard let controller = pipController else {
            print("[PiPManager] pipController is nil")
            return
        }

        // 先取消上一次仍未落地的重试:否则它会在延迟结束后调用
        // `startPictureInPicture()`,用户刚关掉的窗口于是自己回来。
        retryTask?.cancel()
        retryTask = nil

        guard !controller.isPictureInPictureActive else { return }

        wantsPiP = true
        configureAudioSession()
        startFrameLoop()

        // 检查系统当前是否允许开启画中画
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // 如果图层尚未就绪，重试启动（最多等待 1.5 秒）
            print("[PiPManager] isPictureInPicturePossible is false, waiting...")
            retryTask = Task { [weak self] in
                for attempt in 0..<15 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                    guard let self, self.wantsPiP else { return }
                    if controller.isPictureInPicturePossible {
                        controller.startPictureInPicture()
                        print("[PiPManager] Started PiP after retry \(attempt + 1)")
                        return
                    }
                }
                print("[PiPManager] Failed to start PiP: isPictureInPicturePossible remained false")
            }
        }
    }

    func stopPiP() {
        // 在 `guard` 之前清掉:窗口可能还没打开(仍在重试),那种情况下要取消的
        // 只是重试,而不是直接返回、把它留在那里,等它稍后把窗口拉起来。
        wantsPiP = false
        retryTask?.cancel()
        retryTask = nil

        guard let controller = pipController, controller.isPictureInPictureActive else {
            isPiPActive = false
            stopFrameLoop()
            return
        }
        controller.stopPictureInPicture()
    }

    // MARK: - Frame Rendering

    private func startFrameLoop() {
        stopFrameLoop()
        // 首次立即渲染一帧
        renderCurrentSnapshot()
        // 维持约每秒刷新画面(与采样周期 1s 匹配)
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self?.renderCurrentSnapshot()
            }
        }
    }

    private func stopFrameLoop() {
        frameTask?.cancel()
        frameTask = nil
    }

    private func renderCurrentSnapshot() {
        guard let displayLayer = displayLayer else { return }
        guard let monitor = monitor else { return }

        let snapshot = monitor.snapshot
        let image = renderImage(snapshot: snapshot)

        guard let pixelBuffer = pixelBuffer(from: image) else { return }

        // 获取当前 Host Clock 的真实时间戳，或回退到 CACurrentMediaTime
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let format = formatDescription else { return }

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer = sampleBuffer else { return }

        // 设置立即展示附件标记，避免图层等待同步时机导致画面黑屏
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let count = CFArrayGetCount(attachmentsArray)
            if count > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - 画面绘制

    private func renderImage(snapshot: PowerSnapshot) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: canvasSize)

            // 背景色 - 纯黑
            UIColor.black.setFill()
            ctx.fill(rect)

            // 提取数据
            // let batteryPercent = snapshot.percent

            // // 电流：优先使用电池轨/输入电流，或 simulator 寄存器电流
            // let currentVal = snapshot.batteryRailCurrent ?? snapshot.usbInputCurrent ?? snapshot.wirelessInputCurrent ?? snapshot.registryCurrent
            // let currentText: String
            // if let a = currentVal {
            //     currentText = Formatting.amps(abs(a))
            // } else {
            //     currentText = "—"
            // }

            // // 电压：优先使用电池轨/输入电压，或 simulator 寄存器电压
            // let voltageVal = snapshot.batteryRailVoltage ?? snapshot.usbInputVoltage ?? snapshot.wirelessInputVoltage ?? snapshot.registryVoltage
            // let voltageText: String
            // if let v = voltageVal {
            //     voltageText = Formatting.volts(v)
            // } else {
            //     voltageText = "—"
            // }

            // 电流：优先使用 USB 输入电流，其次无线输入/电池轨/模拟器寄存器
            let currentVal =
                snapshot.usbInputCurrent
                ?? snapshot.wirelessInputCurrent
                ?? snapshot.batteryRailCurrent
                ?? snapshot.registryCurrent

            let currentText: String

            if let a = currentVal {
                currentText = Formatting.amps(abs(a))
            } else {
                currentText = "—"
            }

            // 电压：优先使用 USB 输入电压，其次无线输入/电池轨/模拟器寄存器
            let voltageVal =
                snapshot.usbInputVoltage
                ?? snapshot.wirelessInputVoltage
                ?? snapshot.batteryRailVoltage
                ?? snapshot.registryVoltage

            let voltageText: String

            if let v = voltageVal {
                voltageText = Formatting.volts(v)
            } else {
                voltageText = "—"
            }

            // 功耗：从 headline 获取计算功率或直接由 V*A 计算
            let powerVal: Double? = {
                if let headline = self.monitor?.headline {
                    return headline.watts
                }
                if let v = voltageVal, let a = currentVal {
                    return abs(v * a)
                }
                return nil
            }()

            let powerText: String
            if let p = powerVal {
                powerText = Formatting.watts(p) + " W"
            } else {
                powerText = "—"
            }

            let cpuTempText: String
            if let cpu = snapshot.temperature(in: .soc) {
                cpuTempText = Formatting.temperature(cpu)
            } else {
                cpuTempText = "—"
            }

            let battTempText: String
            if let batt = snapshot.temperature(in: .battery) {
                battTempText = Formatting.temperature(batt)
            } else {
                battTempText = "—"
            }

            let chargerTempText: String
            if let chg = snapshot.temperature(in: .charger) {
                chargerTempText = Formatting.temperature(chg)
            } else {
                chargerTempText = "—"
            }

            // 上下左右安全边距
            let paddingLeft: CGFloat = 35
            let paddingRight: CGFloat = 15
            let paddingTop: CGFloat = 32
            let paddingBottom: CGFloat = 18

            // 顶部 MiniWatts 标题 & 充电/放电状态 & 电量百分比
            // let isConnected = snapshot.externalConnected
            // let statusString = isConnected ? "Charging" : "Discharging"
            // let titleString = "Key • \(statusString)"
            // let titleAttrs: [NSAttributedString.Key: Any] = [
            //     .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
            //     .foregroundColor: UIColor(white: 0.72, alpha: 1.0)
            // ]
            // (titleString as NSString).draw(at: CGPoint(x: paddingLeft, y: paddingTop), withAttributes: titleAttrs)

            // if let pct = batteryPercent {
            //     let batteryString = "\(pct)%"
            //     let batteryAttrs: [NSAttributedString.Key: Any] = [
            //         .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            //         .foregroundColor: UIColor(white: 0.72, alpha: 1.0)
            //     ]
            //     let batterySize = (batteryString as NSString).size(withAttributes: batteryAttrs)
            //     let batteryX = canvasSize.width - paddingRight - batterySize.width
            //     (batteryString as NSString).draw(at: CGPoint(x: batteryX, y: paddingTop - 2), withAttributes: batteryAttrs)
            // }

            // 网格布局：2行 × 3列
            // 行 1: 电流 (Current) | 电压 (Voltage) | 功耗 (Power)
            // 行 2: CPU温度 (CPU)  | 电池温度 (Batt) | 充电IC温度 (Charger)
            struct Item {
                let label: String
                let value: String
                let color: UIColor
            }

            let yellowColor = UIColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0)
            let blueColor = UIColor(red: 0.40, green: 0.72, blue: 1.0, alpha: 1.0)
            let greenColor = UIColor(red: 0.35, green: 0.90, blue: 0.50, alpha: 1.0)
            let orangeColor = UIColor(red: 1.0, green: 0.60, blue: 0.28, alpha: 1.0)
            let cyanColor = UIColor(red: 0.40, green: 0.90, blue: 0.90, alpha: 1.0)
            let purpleColor = UIColor(red: 0.86, green: 0.60, blue: 1.0, alpha: 1.0)

            let row1: [Item] = [
                Item(label: "CURRENT", value: currentText, color: yellowColor),
                Item(label: "VOLTAGE", value: voltageText, color: blueColor),
                Item(label: "POWER", value: powerText, color: greenColor)
            ]

            let row2: [Item] = [
                Item(label: "CPU TEMP", value: cpuTempText, color: orangeColor),
                Item(label: "BATT TEMP", value: battTempText, color: cyanColor),
                Item(label: "CHG IC", value: chargerTempText, color: purpleColor)
            ]

            let availableWidth = canvasSize.width - paddingLeft - paddingRight
            let colWidth: CGFloat = 170
            let colSpacing: CGFloat = (availableWidth - (colWidth * 3)) / 2

            // 绘制第 1 行与第 2 行 (上下居中排版)
            // let row1Y: CGFloat = paddingTop + 44
            let row1Y: CGFloat = 28
            for (idx, item) in row1.enumerated() {
                let x = paddingLeft + CGFloat(idx) * (colWidth + colSpacing)
                drawItem((label: item.label, value: item.value, color: item.color), atX: x, topY: row1Y)
            }

            // let row2Y: CGFloat = row1Y + 128
            let row2Y = row1Y + 108
            for (idx, item) in row2.enumerated() {
                let x = paddingLeft + CGFloat(idx) * (colWidth + colSpacing)
                drawItem((label: item.label, value: item.value, color: item.color), atX: x, topY: row2Y)
            }
        }
    }

    private func drawItem(_ item: (label: String, value: String, color: UIColor), atX x: CGFloat, topY y: CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: UIColor(white: 0.55, alpha: 1.0)
        ]
        (item.label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: labelAttrs)

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .bold),
            .foregroundColor: item.color
        ]
        (item.value as NSString).draw(at: CGPoint(x: x, y: y + 28), withAttributes: valueAttrs)
    }

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var pixelBuffer: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess,
            let buffer = pixelBuffer,
            let cgImage = image.cgImage else {
            return nil
        }

    CVPixelBufferLockBaseAddress(buffer, [])

        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high

        context.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )

        return buffer
    }

    // MARK: - Delegate callbacks

    /// Called by `Proxy`, on the main thread when the window is up.
    fileprivate func didStart() {
        isPiPActive = true
        startFrameLoop()
    }

    /// Called by `Proxy`, on the main thread once the window is gone. This is the
    /// only path left that records a user closing the window — it is what stops the
    /// window from coming back when the app next goes to the background, so it must
    /// clear `wantsPiP` as well as the flag the button reads.
    fileprivate func didStop() {
        wantsPiP = false
        isPiPActive = false
        retryTask?.cancel()
        retryTask = nil
        stopFrameLoop()
    }

    /// Called by `Proxy`, on the main thread.
    fileprivate func didFail(_ error: any Error) {
        print("[PiPManager] PiP failed to start: \(error)")
        wantsPiP = false
        isPiPActive = false
        stopFrameLoop()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    /// AVKit's callbacks are not main-actor annotated, so they cannot be witnessed
    /// by this project's (main-actor by default) methods. They do arrive on the main
    /// thread, hence `assumeIsolated` rather than a hop, which would report a
    /// stopped window a frame late.
    ///
    /// One `AVSampleBufferDisplayLayer` and one controller per process: MiniWatts is
    /// too small to need a second one.
    private final class Proxy: NSObject, AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate {
        private weak var owner: PiPManager?

        init(owner: PiPManager) {
            self.owner = owner
        }

        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { owner?.didStart() }
        }

        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    failedToStartPictureInPictureWithError error: any Error) {
            MainActor.assumeIsolated { owner?.didFail(error) }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { owner?.didStop() }
        }

        /// Tapping the window's restore button brings MiniWatts back. There is no
        /// player UI to put back together, so the window just closes.
        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

        // The window is a readout, not a player: it is always live, never paused, and
        // there is nothing to seek.
        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    setPlaying playing: Bool) {}

        nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
            CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
            false
        }

        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    skipByInterval skipInterval: CMTime,
                                                    completion completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        /// No sound of ours to protect, and silencing another app's would be rude.
        nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
            false
        }
    }
}
