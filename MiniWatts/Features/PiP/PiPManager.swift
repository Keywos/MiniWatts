import UIKit
import AVKit
import SwiftUI

/// 驱动画中画（Picture in Picture）窗口并在其中以自绘画面实时显示各项功耗与温度指标
@MainActor
final class PiPManager: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPManager()

    var isActive: Bool { isPiPActive }
    private(set) var isPiPActive: Bool = false {
        didSet {
            onStateChanged?(isPiPActive)
        }
    }

    var onStateChanged: ((Bool) -> Void)?

    private var pipController: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipSourceView: UIView?
    private var timer: Timer?
    private weak var monitor: PowerMonitor?

    private let canvasSize = CGSize(width: 320, height: 180)

    override private init() {
        super.init()
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

        let layer: AVSampleBufferDisplayLayer
        if let customView = containerView as? SampleBufferContainerView {
            layer = customView.sampleBufferLayer
            layer.videoGravity = .resizeAspect
            self.pipSourceView = customView
        } else {
            layer = AVSampleBufferDisplayLayer()
            layer.frame = CGRect(x: 0, y: 0, width: 64, height: 36)
            layer.videoGravity = .resizeAspect
            layer.opacity = 0.05

            let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 36))
            sourceView.backgroundColor = .black
            sourceView.alpha = 0.05
            sourceView.layer.addSublayer(layer)
            containerView.addSubview(sourceView)

            self.pipSourceView = sourceView
        }

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

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        self.pipController = controller

        // 预热并喂一帧，使 isPictureInPicturePossible 尽快就绪
        renderCurrentSnapshot()
    }

    func togglePiP() {
        if isPiPActive {
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
        guard !controller.isPictureInPictureActive else { return }

        configureAudioSession()
        startFrameTimer()

        // 检查系统当前是否允许开启画中画
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // 如果图层尚未就绪，重试启动（最多等待 1.5 秒）
            print("[PiPManager] isPictureInPicturePossible is false, waiting...")
            var retries = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                retries += 1
                if controller.isPictureInPicturePossible {
                    t.invalidate()
                    controller.startPictureInPicture()
                    print("[PiPManager] Started PiP after retry \(retries)")
                } else if retries >= 15 {
                    t.invalidate()
                    print("[PiPManager] Failed to start PiP: isPictureInPicturePossible remained false")
                }
            }
        }
    }

    func stopPiP() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    // MARK: - Frame Rendering

    private func startFrameTimer() {
        stopFrameTimer()
        // 首次立即渲染一帧
        renderCurrentSnapshot()
        // 维持约每秒刷新画面（与采样周期 1s 匹配）
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderCurrentSnapshot()
            }
        }
    }

    private func stopFrameTimer() {
        timer?.invalidate()
        timer = nil
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
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: canvasSize)

            // 背景色 - 深黑底
            UIColor(white: 0.08, alpha: 1.0).setFill()
            ctx.fill(rect)

            // 装饰卡片外框
            let roundedPath = UIBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 14)
            UIColor(white: 0.16, alpha: 1.0).setStroke()
            roundedPath.lineWidth = 1.0
            roundedPath.stroke()

            // 提取数据
            let batteryPercent = snapshot.percent

            // 电流：优先使用电池轨/输入电流，或 simulator 寄存器电流
            let currentVal = snapshot.batteryRailCurrent ?? snapshot.usbInputCurrent ?? snapshot.wirelessInputCurrent ?? snapshot.registryCurrent
            let currentText: String
            if let a = currentVal {
                currentText = Formatting.amps(abs(a))
            } else {
                currentText = "—"
            }

            // 电压：优先使用电池轨/输入电压，或 simulator 寄存器电压
            let voltageVal = snapshot.batteryRailVoltage ?? snapshot.usbInputVoltage ?? snapshot.wirelessInputVoltage ?? snapshot.registryVoltage
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

            // 顶部 MiniWatts 标题 & 充电/放电状态 & 电量百分比
            let isConnected = snapshot.externalConnected
            let statusString = isConnected ? "Charging" : "Discharging"
            let titleString = "MiniWatts • \(statusString)"
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor(white: 0.7, alpha: 1.0)
            ]
            (titleString as NSString).draw(at: CGPoint(x: 14, y: 10), withAttributes: titleAttrs)

            if let pct = batteryPercent {
                let batteryString = "🔋 \(pct)%"
                let batteryAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let batterySize = (batteryString as NSString).size(withAttributes: batteryAttrs)
                let batteryX = canvasSize.width - 14 - batterySize.width
                (batteryString as NSString).draw(at: CGPoint(x: batteryX, y: 9), withAttributes: batteryAttrs)
            }

            // 网格布局：2行 × 3列
            // 行 1: 电流 (Current) | 电压 (Voltage) | 功耗 (Power)
            // 行 2: CPU温度 (CPU)  | 电池温度 (Batt) | 充电IC温度 (Charger)
            struct Item {
                let label: String
                let value: String
                let color: UIColor
            }

            let yellowColor = UIColor(red: 0.98, green: 0.78, blue: 0.25, alpha: 1.0)
            let blueColor = UIColor(red: 0.35, green: 0.65, blue: 0.98, alpha: 1.0)
            let greenColor = UIColor(red: 0.32, green: 0.85, blue: 0.45, alpha: 1.0)
            let orangeColor = UIColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1.0)
            let cyanColor = UIColor(red: 0.35, green: 0.85, blue: 0.85, alpha: 1.0)
            let purpleColor = UIColor(red: 0.82, green: 0.55, blue: 0.98, alpha: 1.0)

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

            let colWidth: CGFloat = 96
            let colStartX: CGFloat = 16
            let colSpacing: CGFloat = (canvasSize.width - (colStartX * 2) - (colWidth * 3)) / 2

            // 绘制第 1 行
            let row1Y: CGFloat = 34
            for (idx, item) in row1.enumerated() {
                let x = colStartX + CGFloat(idx) * (colWidth + colSpacing)
                drawItem((label: item.label, value: item.value, color: item.color), atX: x, topY: row1Y)
            }

            // 绘制第 2 行
            let row2Y: CGFloat = 104
            for (idx, item) in row2.enumerated() {
                let x = colStartX + CGFloat(idx) * (colWidth + colSpacing)
                drawItem((label: item.label, value: item.value, color: item.color), atX: x, topY: row2Y)
            }
        }
    }

    private func drawItem(_ item: (label: String, value: String, color: UIColor), atX x: CGFloat, topY y: CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: UIColor(white: 0.5, alpha: 1.0)
        ]
        (item.label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: labelAttrs)

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: item.color
        ]
        (item.value as NSString).draw(at: CGPoint(x: x, y: y + 17), withAttributes: valueAttrs)
    }

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
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

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let pixelData = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        if let cgImage = image.cgImage, let context = context {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return buffer
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
        startFrameTimer()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPiPActive = false
        stopFrameTimer()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        stopFrameTimer()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        stopFrameTimer()
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // 画中画窗口上的播放/暂停按钮
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // 实时流返回无限或当前时刻
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion handler: @escaping () -> Void
    ) {
        handler()
    }
}
