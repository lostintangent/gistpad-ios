#if os(iOS)
import SwiftUI
import UIKit

struct NoteFileSubtitle: UIViewControllerRepresentable {
    let filename: String?

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.filename = filename
        controller.updateSubtitle()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.removeSubtitle()
    }

    final class Controller: UIViewController {
        var filename: String?
        private let subtitle = SubtitleView()
        private weak var configuredItem: UINavigationItem?

        override func loadView() {
            view = UIView()
            view.isHidden = true
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil { removeSubtitle() } else { updateSubtitle() }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            updateSubtitle()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateSubtitle()
        }

        func updateSubtitle() {
            guard let owner = sequence(first: self as UIViewController, next: \.parent)
                .first(where: { candidate in
                    candidate.navigationController?.viewControllers.contains(where: { $0 === candidate }) == true
                }) else { return }
            let item = owner.navigationItem
            if configuredItem !== item { removeSubtitle() }
            configuredItem = item
            guard let filename else {
                removeSubtitle()
                return
            }
            if subtitle.label.text != filename {
                subtitle.label.text = filename
                subtitle.invalidateIntrinsicContentSize()
                subtitle.setNeedsLayout()
            }
            if item.subtitleView !== subtitle { item.subtitleView = subtitle }
        }

        func removeSubtitle() {
            if configuredItem?.subtitleView === subtitle { configuredItem?.subtitleView = nil }
            configuredItem = nil
        }
    }

    private final class SubtitleView: UIView {
        let label = UILabel()
        private var topInset: CGFloat {
            UIFontMetrics(forTextStyle: .body).scaledValue(for: 4, compatibleWith: traitCollection)
        }

        init() {
            super.init(frame: .zero)
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
            label.accessibilityIdentifier = "note-header-filename"
            addSubview(label)
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SubtitleView, _) in
                view.invalidateIntrinsicContentSize()
                view.setNeedsLayout()
            }
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: CGSize {
            let size = label.intrinsicContentSize
            return CGSize(width: size.width, height: size.height + topInset)
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let size = label.sizeThatFits(CGSize(width: size.width, height: max(0, size.height - topInset)))
            return CGSize(width: size.width, height: size.height + topInset)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds.inset(by: UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0))
        }
    }
}
#endif
