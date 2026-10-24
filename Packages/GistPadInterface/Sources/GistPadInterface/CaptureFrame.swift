#if os(iOS)
import SwiftUI
import UIKit

extension View {
    public func captureFrame(_ identifier: String) -> some View {
        #if DEBUG
        background { CaptureFrameView(identifier: identifier) }
        #else
        self
        #endif
    }
}

#if DEBUG
private struct CaptureFrameView: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.accessibilityIdentifier = "capture-frame-\(identifier)"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
#endif
