import SwiftUI
import UIKit

/// 负责将底层 AVSampleBufferDisplayLayer 宿主 UIView 挂载到 SwiftUI 视图层级中，并绑定 PiPManager
struct PiPAnchorView: UIViewRepresentable {
    @Environment(PowerMonitor.self) private var monitor

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // 延迟至下一运行循环，确保 view 已经加入 window 层级
        DispatchQueue.main.async {
            PiPManager.shared.setup(with: monitor, in: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 不需要每次更新重绘
    }
}
