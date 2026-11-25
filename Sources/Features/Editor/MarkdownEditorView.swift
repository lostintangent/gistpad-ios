#if canImport(UIKit)
    import Appearance
    import Comments
    import Markdown
    import SwiftUI
    import UIKit

    public struct MarkdownEditorView: View {
        let editor: MarkdownEditor
        /// What VoiceOver calls the text view: the title the screen shows.
        private let title: String?
        private let insertImage: (@MainActor () -> Void)?
        private let intelligence: (@MainActor () -> Void)?
        private let comments: CommentAnnotations?
        @State private var linkRequest: LinkRequest?

        public init(
            editor: MarkdownEditor,
            title: String? = nil,
            insertImage: (@MainActor () -> Void)? = nil,
            intelligence: (@MainActor () -> Void)? = nil,
            comments: CommentAnnotations? = nil
        ) {
            self.editor = editor
            self.title = title
            self.insertImage = insertImage
            self.intelligence = intelligence
            self.comments = comments
        }

        public var body: some View {
            TextViewRepresentable(
                editor: editor, title: title,
                comments: comments,
                actions: KeyboardBarActions(
                    canFormat: editor.canFormat,
                    format: format, link: beginLink, indent: { editor.indent(outdent: $0) },
                    image: insertImage,
                    intelligence: editor.isSettled ? intelligence : nil,
                    dismiss: editor.endEditing)
            )
            .id(editor.id)
            .ignoresSafeArea([.container, .keyboard], edges: .vertical)
            .sheet(item: $linkRequest, onDismiss: editor.focus) { request in
                LinkEditor(label: request.label) { label, destination throws(MarkdownEditor.Failure) in
                    guard let edit = request.document.edit(linking: request.selection, to: destination, label: label)
                    else { throw .invalidLink }
                    try editor.apply(edit)
                }
            }
            .alert(error: Bindable(editor).inputError) {}
        }

        private func format(_ command: (MarkdownDocument, NSRange) -> MarkdownEdit?) {
            editor.perform(command(editor.document, editor.textView.selectedRange))
        }

        private func beginLink() {
            guard editor.canFormat else { return editor.inputError = .unsettled }
            linkRequest = LinkRequest(document: editor.document, selection: editor.textView.selectedRange)
        }

    }

    private struct TextViewRepresentable: UIViewRepresentable {
        let editor: MarkdownEditor
        let title: String?
        let comments: CommentAnnotations?
        let actions: KeyboardBarActions
        @Environment(\.isPaneVisible) private var isPaneVisible
        @Environment(\.accent) private var accent

        func makeCoordinator() -> KeyboardBar {
            KeyboardBar(actions: actions)
        }

        func makeUIView(context: Context) -> TextViewHost {
            let host = TextViewHost(editor: editor)
            updateUIView(host, context: context)
            return host
        }

        func updateUIView(_ host: TextViewHost, context: Context) {
            let accessory = context.coordinator
            host.configure { view in
                view.isHidden = !isPaneVisible
                view.isAccessibilityElement = isPaneVisible
                view.accessibilityElementsHidden = !isPaneVisible
                view.accessibilityLabel = title
                accessory.update(actions: actions)
                accessory.textView = view
                if view.inputAccessoryView !== accessory {
                    view.inputAccessoryView = accessory
                    if view.isFirstResponder { view.reloadInputViews() }
                }
                view.traitOverrides[AccentTrait.self] = accent
                editor.commentAnnotator.configure(comments)
            }
            host.isPaneVisible = isPaneVisible
        }

        static func dismantleUIView(_ host: TextViewHost, coordinator: KeyboardBar) {
            host.dismantle()
        }
    }

    final class TextViewHost: UIView {
        struct Reference {
            weak var host: TextViewHost?
        }

        private let editor: MarkdownEditor
        private var configuration: ((UITextView) -> Void)?
        private var isDismantled = false
        var isPaneVisible = true {
            didSet { if isPaneVisible, !oldValue { handBarSource() } }
        }

        init(editor: MarkdownEditor) {
            self.editor = editor
            super.init(frame: .zero)
            editor.hosts.append(Reference(host: self))
            // Platform gap: a keyboard guide move only lays out views constrained to it, so a hidden view
            // pinned to it lays out the host. Remove with the source's keyboard inset.
            let keyboardEdge = UIView()
            keyboardEdge.isHidden = true
            keyboardEdge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keyboardEdge)
            NSLayoutConstraint.activate([
                keyboardEdge.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                keyboardEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
                keyboardEdge.widthAnchor.constraint(equalToConstant: 0),
                keyboardEdge.heightAnchor.constraint(equalToConstant: 0),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(editor:)") }

        func configure(_ configuration: @escaping (UITextView) -> Void) {
            guard !isDismantled else { return }
            self.configuration = configuration
            if ownsEditor { configuration(editor.textView) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !isDismantled else { return }
            updateOwnership()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil, !isDismantled else { return }
            if editor.host?.window == nil { updateOwnership() }
            guard editor.host === self else { return }
            if !ownsEditor { adoptEditor() }
            if editor.textView.frame != bounds { editor.textView.frame = bounds }
            editor.textView.keyboardOverlap = bounds.maxY - keyboardLayoutGuide.layoutFrame.minY
            // Platform gap: the keyboard lays out its accessory after a column animation, so the capsule
            // would jump. Laying it out now glides it with the note. Remove when UIKit animates it along.
            if let accessory = editor.textView.inputAccessoryView, accessory.window != nil {
                accessory.setNeedsLayout()
                accessory.layoutIfNeeded()
            }
        }

        func dismantle() {
            isDismantled = true
            configuration = nil
            updateOwnership()
            guard editor.host == nil, editor.textView.superview === self else { return }
            editor.commentAnnotator.configure(nil)
            editor.textView.inputAccessoryView = nil
            editor.textView.removeFromSuperview()
        }

        private var ownsEditor: Bool {
            editor.host === self && editor.textView.superview === self
        }

        private func updateOwnership() {
            editor.hosts.removeAll {
                $0.host == nil || $0.host?.isDismantled == true
            }
            // Re-entering an older native column must not supersede a newer live host.
            let owner = editor.hosts.last { $0.host?.window != nil }?.host
            guard editor.host !== owner || owner?.ownsEditor == false else { return }
            editor.host = owner
            owner?.adoptEditor()
        }

        private func adoptEditor() {
            guard window != nil, editor.host === self, !isDismantled else { return }
            // SwiftUI owns this container, never the text view shared with another host.
            let textView = editor.textView
            textView.frame = bounds
            textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            configuration?(textView)
            addSubview(textView)
            handBarSource()
        }

        // Platform gap: the bar can't find a scroll view inside a UIViewRepresentable, so it neither
        // minimizes nor draws its soft edge over the source. Remove when SwiftUI hands the bar the
        // source. The bar follows the pane that last appeared or that you last scrolled.
        func handBarSource() {
            guard window != nil, isPaneVisible, ownsEditor else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let screen = current as? UIViewController, screen.parent is UINavigationController {
                    if screen.contentScrollView(for: .top) !== editor.textView {
                        screen.setContentScrollView(editor.textView, for: .top)
                    }
                    return
                }
                responder = current.next
            }
        }
    }

    /// The selection a link is being added to, in the document it was chosen from.
    private struct LinkRequest: Identifiable {
        let id = UUID()
        let document: MarkdownDocument
        let selection: NSRange
        var label: String { (document.text as NSString).substring(with: selection) }
    }

    private struct LinkEditor: View {
        @State var label: String
        @State private var destination = ""
        @State private var error: String?
        @FocusState private var urlFocused: Bool
        let save: @MainActor (String, String) throws(MarkdownEditor.Failure) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    TextField(String(localized: "Text", bundle: .module), text: $label)
                    TextField(String(localized: "URL", bundle: .module), text: $destination)
                        .focused($urlFocused)
                        .accessibilityIdentifier("link-url")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle(String(localized: "Add Link", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) { insert() }
                            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .task { urlFocused = true }
        }

        private func insert() {
            do {
                try save(label, destination)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
#endif
