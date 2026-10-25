#if os(iOS)
import SwiftUI
import UIKit

struct LibrarySearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    @Binding var windowContentWidth: CGFloat?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isPresented: $isPresented)
    }

    func makeUIView(context: Context) -> SearchBar {
        let bar = SearchBar()
        bar.delegate = context.coordinator
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        bar.searchTextField.attributedPlaceholder = NSAttributedString(
            string: String(localized: "Search notes", bundle: .module),
            attributes: [.paragraphStyle: paragraph])
        bar.tintColor = .label
        bar.searchTextField.tintColor = .systemBlue
        bar.searchTextField.adjustsFontSizeToFitWidth = false
        bar.searchTextField.accessibilityIdentifier = "library-search-field"
        bar.onWindowContentWidthChange = { windowContentWidth = $0 }
        return bar
    }

    func updateUIView(_ bar: SearchBar, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isPresented = $isPresented
        bar.onWindowContentWidthChange = { windowContentWidth = $0 }
        if bar.text != text, bar.searchTextField.markedTextRange == nil {
            bar.text = text
        }
        bar.updateTrailingClearance()
        bar.wantsFocus = isPresented
        bar.setShowsCancelButton(isPresented, animated: !context.transaction.disablesAnimations)
        if isPresented, bar.window != nil, !bar.searchTextField.isFirstResponder {
            bar.searchTextField.becomeFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SearchBar, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @MainActor
    final class Coordinator: NSObject, UISearchBarDelegate {
        var text: Binding<String>
        var isPresented: Binding<Bool>

        init(text: Binding<String>, isPresented: Binding<Bool>) {
            self.text = text
            self.isPresented = isPresented
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text.wrappedValue = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            if !isPresented.wrappedValue { isPresented.wrappedValue = true }
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        }

        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.text = ""
            text.wrappedValue = ""
            isPresented.wrappedValue = false
            searchBar.searchTextField.resignFirstResponder()
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            isPresented.wrappedValue = false
            searchBar.searchTextField.resignFirstResponder()
        }
    }

    @MainActor
    final class SearchBar: UISearchBar {
        var wantsFocus = false
        var onWindowContentWidthChange: ((CGFloat) -> Void)?
        private let glass: UIVisualEffectView
        private var reportedWindowContentWidth: CGFloat?

        override init(frame: CGRect) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            glass = UIVisualEffectView(effect: effect)
            super.init(frame: frame)
            searchBarStyle = .minimal
            setSearchFieldBackgroundImage(UIImage(), for: .normal)
            let trailingSpace = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
            trailingSpace.isUserInteractionEnabled = false
            trailingSpace.accessibilityElementsHidden = true
            searchTextField.rightView = trailingSpace
            searchTextField.addTarget(
                self, action: #selector(updateTrailingClearance), for: .editingChanged)
            updateTrailingClearance()
            glass.cornerConfiguration = .capsule()
            glass.isUserInteractionEnabled = false
            glass.accessibilityElementsHidden = true
            glass.translatesAutoresizingMaskIntoConstraints = false
            searchTextField.insertSubview(glass, at: 0)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: searchTextField.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: searchTextField.trailingAnchor),
                glass.topAnchor.constraint(equalTo: searchTextField.topAnchor),
                glass.bottomAnchor.constraint(equalTo: searchTextField.bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc func updateTrailingClearance() {
            searchTextField.rightViewMode = (text ?? "").isEmpty ? .always : .never
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportWindowContentWidth()
            if window != nil, wantsFocus {
                searchTextField.becomeFirstResponder()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // UISearchBar scales its placeholder independently of the text-fitting flag.
            if let font = searchTextField.font, searchTextField.minimumFontSize != font.pointSize {
                searchTextField.minimumFontSize = font.pointSize
            }
            reportWindowContentWidth()
        }

        private func reportWindowContentWidth() {
            guard let window else { return }
            let width = window.bounds.width - window.safeAreaInsets.left - window.safeAreaInsets.right
            guard reportedWindowContentWidth != width else { return }
            reportedWindowContentWidth = width
            Task { @MainActor [weak self] in
                guard let self, reportedWindowContentWidth == width else { return }
                onWindowContentWidthChange?(width)
            }
        }
    }
}
#endif
