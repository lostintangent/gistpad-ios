#if canImport(UIKit)
  import Appearance
  import Comments
  import SwiftUI
  import UIKit

  public struct EditorView: View {
    public let editor: Editor
    /// What VoiceOver calls the text view: the title the screen shows.
    private let title: String?
    private let insertImage: (@MainActor () -> Void)?
    private let intelligence: (@MainActor () -> Void)?
    private let comments: CommentHighlightConfiguration
    private let commentActions: CommentHighlightActions?
    @State private var linkRequest: LinkRequest?

    public init(
      editor: Editor,
      title: String? = nil,
      insertImage: (@MainActor () -> Void)? = nil,
      intelligence: (@MainActor () -> Void)? = nil,
      comments: CommentHighlightConfiguration = .init(),
      commentActions: CommentHighlightActions? = nil
    ) {
      self.editor = editor
      self.title = title
      self.insertImage = insertImage
      self.intelligence = intelligence
      self.comments = comments
      self.commentActions = commentActions
    }

    public var body: some View {
      GeometryReader { _ in
        TextViewRepresentable(
          editor: editor, title: title,
          comments: comments, commentActions: commentActions,
          actions: KeyboardBarActions(
            canFormat: editor.canFormat,
            format: format, link: beginLink, indent: { editor.indent(outdent: $0) },
            image: insertImage,
            intelligence: editor.isSettled ? intelligence : nil,
            dismiss: { editor.textView.resignFirstResponder() })
        )
        .id(editor.id)
        .ignoresSafeArea([.container, .keyboard], edges: .vertical)
      }
      .overlay { ViewportRepresentable(editor: editor).allowsHitTesting(false) }
      .sheet(
        item: $linkRequest,
        onDismiss: {
          if editor.textView.window != nil, editor.textView.isEditable {
            editor.textView.becomeFirstResponder()
          }
        }
      ) { request in
        LinkEditor(label: request.label) { label, destination in
          if let edit = try Format.link(label: label, destination: destination).edit(
            in: request.source, selection: request.selection)
          {
            try editor.apply(edit, generation: request.generation)
          }
        }
      }
      .alert(
        String(localized: "Couldn't Complete Action", bundle: .module),
        item: Bindable(editor).inputError
      ) { _ in
        Button(String(localized: "OK", bundle: .module), role: .cancel) {}
      } message: { message in
        Text(message)
      }
    }

    private func format(_ command: Format) {
      do {
        if let edit = try command.edit(in: editor.text, selection: editor.textView.selectedRange) {
          try editor.apply(edit, generation: editor.generation)
        }
      } catch {
        editor.inputError = error.localizedDescription
      }
    }

    private func beginLink() {
      let selection = editor.textView.selectedRange
      do {
        guard editor.canFormat else { throw Edit.Failure.unsettled }
        linkRequest = LinkRequest(
          source: editor.text, generation: editor.generation, selection: selection,
          label: try Edit.text(in: editor.text, at: selection))
      } catch {
        editor.inputError = error.localizedDescription
      }
    }

  }

  private struct TextViewRepresentable: UIViewRepresentable {
    let editor: Editor
    let title: String?
    let comments: CommentHighlightConfiguration
    let commentActions: CommentHighlightActions?
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
        editor.setCommentHighlights(comments, actions: commentActions)
      }
    }

    static func dismantleUIView(_ host: TextViewHost, coordinator: KeyboardBar) {
      host.dismantle()
    }
  }

  final class TextViewHost: UIView {
    struct Reference {
      weak var host: TextViewHost?
    }

    private let editor: Editor
    private var configuration: ((UITextView) -> Void)?
    private var isDismantled = false

    init(editor: Editor) {
      self.editor = editor
      super.init(frame: .zero)
      editor.hosts.append(Reference(host: self))
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
      // Laying out now, inside any column animation, lets the keyboard capsule glide with the note.
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
      editor.setCommentHighlights(.init())
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
    }
  }

  private struct ViewportRepresentable: UIViewRepresentable {
    let editor: Editor

    func makeUIView(context: Context) -> ViewportView {
      let view = ViewportView()
      view.textView = editor.textView
      editor.textView.updateViewportView(view)
      return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
      view.textView = editor.textView
      editor.textView.updateViewportView(view)
    }
  }

  private final class ViewportView: UIView {
    weak var textView: UITextView?
    private let topEdge = UIScrollEdgeElementContainerInteraction()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
      topEdge.edge = .top
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      updateChrome()
      textView?.setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateChrome()
      textView?.setNeedsLayout()
    }

    private func updateChrome() {
      var responder: UIResponder? = self
      var navigationBar: UINavigationBar?
      while let current = responder, window != nil {
        if let controller = current as? UIViewController,
          let bar = controller.navigationController?.navigationBar, bar.window === window
        {
          navigationBar = bar
          break
        }
        responder = current.next
      }
      guard topEdge.view !== navigationBar || topEdge.scrollView !== textView else { return }
      topEdge.view?.removeInteraction(topEdge)
      topEdge.scrollView = textView
      navigationBar?.addInteraction(topEdge)
    }
  }

  private struct LinkRequest: Identifiable {
    let id = UUID()
    let source: String
    let generation: UInt64
    let selection: NSRange
    let label: String
  }

  private struct LinkEditor: View {
    @State var label: String
    @State private var destination = ""
    @State private var error: String?
    @FocusState private var urlFocused: Bool
    let save: @MainActor (String, String) throws -> Void
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
