import SwiftUI
import UIKit
import AVFoundation

/// 负责将底层 AVSampleBufferDisplayLayer 宿主 UIView 挂载到 SwiftUI 视图层级中，并绑定 PiPManager
struct PiPAnchorView: UIViewRepresentable {
    @Environment(PowerMonitor.self) private var monitor

    func makeUIView(context: Context) -> UIView {
        let view = SampleBufferContainerView(frame: CGRect(x: 0, y: 0, width: 64, height: 36))
        view.backgroundColor = .black
        view.alpha = 0.05
        view.isUserInteractionEnabled = false
        
        DispatchQueue.main.async {
            PiPManager.shared.setup(with: monitor, in: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
    }
}

final class SampleBufferContainerView: UIView {
    override static var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }
    
    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}
