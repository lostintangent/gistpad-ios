#if DEBUG
import SwiftUI
import UIKit

struct MarkerCaptureContrast: UIViewRepresentable {
    let increased: Bool

    func makeUIView(context: Context) -> MarkerCaptureContrastView {
        MarkerCaptureContrastView(increased: increased)
    }

    func updateUIView(_ view: MarkerCaptureContrastView, context: Context) {}
}

final class MarkerCaptureContrastView: UIView {
    private let increased: Bool

    init(increased: Bool) {
        self.increased = increased
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window?.traitOverrides.accessibilityContrast = increased ? .high : .normal
    }
}
#endif
