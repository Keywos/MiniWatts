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

    // private let canvasSize = CGSize(width: 640, height: 360)
    // private let outputSize = CGSize(width: 1280, height: 720)
    private let canvasSize = CGSize(width: 640, height: 240)
    private let outputSize = CGSize(width: 1280, height: 480)

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
