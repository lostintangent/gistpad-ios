#if canImport(UIKit)
  import GistPadAccent
  import GistPadComments
  import SwiftUI
  import UIKit

  public struct EditorView: View {
    public let editor: Editor
    /// What VoiceOver calls the text view: the title the screen shows.
    private let title: String?
    private let insertImage: (@MainActor () -> Void)?
    private let canInsertImage: Bool
    private let intelligence: (@MainActor () -> Void)?
    private let comments: CommentHighlightConfiguration
    private let onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
    private let onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
    private let onAddComment: (@MainActor (String) -> Void)?
    @State private var linkRequest: LinkRequest?
    @State private var actionError: String?

    public init(
      editor: Editor,
      title: String? = nil,
      insertImage: (@MainActor () -> Void)? = nil,
      canInsertImage: Bool = false,
      intelligence: (@MainActor () -> Void)? = nil,
      comments: CommentHighlightConfiguration = .init(),
      onOpenCommentThreads: (@MainActor ([Int64]) -> Void)? = nil,
      onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)? = nil,
      onAddComment: (@MainActor (String) -> Void)? = nil
    ) {
      self.editor = editor
      self.title = title
      self.insertImage = insertImage
      self.canInsertImage = canInsertImage
      self.intelligence = intelligence
      self.comments = comments
      self.onOpenCommentThreads = onOpenCommentThreads
      self.onLinkedCommentIDsChange = onLinkedCommentIDsChange
      self.onAddComment = onAddComment
    }

    public var body: some View {
      GeometryReader { _ in
        TextViewRepresentable(
          editor: editor, title: title,
          comments: comments, onOpenCommentThreads: onOpenCommentThreads,
          onLinkedCommentIDsChange: onLinkedCommentIDsChange,
          onAddComment: onAddComment,
          actions: KeyboardBarActions(
            format: format, link: beginLink, indent: indent,
            image: insertImage,
            intelligence: intelligence,
            dismiss: { editor.textView.resignFirstResponder() }),
          configuration: KeyboardBarConfiguration(
            canFormat: editor.canFormat,
            canInsertImage: canInsertImage && insertImage != nil,
            canUseIntelligence: editor.isSettled && intelligence != nil)
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
          if let edit = try Formatting.edit(
            .link(label: label, destination: destination), in: request.source,
            selection: request.selection)
          {
            try editor.apply(edit, generation: request.generation)
          }
        }
      }
      .alert(
        String(localized: "Couldn't Complete Action", bundle: .module),
        isPresented: Binding(
          get: { actionError != nil || editor.inputError != nil },
          set: {
            if !$0 {
              actionError = nil
              editor.inputError = nil
            }
          })
      ) {
        Button(String(localized: "OK", bundle: .module), role: .cancel) {
          actionError = nil
          editor.inputError = nil
        }
      } message: {
        Text(actionError ?? editor.inputError ?? "")
      }
    }

    private func format(_ command: Format) {
      do {
        if let edit = try Formatting.edit(
          command, in: editor.text, selection: editor.textView.selectedRange)
        {
          try editor.apply(edit, generation: editor.generation)
        }
      } catch Edit.MutationError.compositionActive {
        actionError = String(
          localized: "Finish typing or wait for Writing Tools, then try again.", bundle: .module)
      } catch {
        actionError = String(localized: "The file changed. Select the text again.", bundle: .module)
      }
    }

    private func beginLink() {
      let selection = editor.textView.selectedRange
      guard editor.canFormat, let label = try? Edit.text(in: editor.text, at: selection)
      else {
        actionError = String(
          localized: "Finish the current text edit, then select the link text again.",
          bundle: .module)
        return
      }
      linkRequest = LinkRequest(
        source: editor.text, generation: editor.generation, selection: selection, label: label)
    }

    private func indent(outdent: Bool) {
      do {
        try editor.indent(outdent: outdent)
      } catch {
        actionError = String(
          localized: "Finish the current text edit, then select the lines again.", bundle: .module)
      }
    }

  }

  private struct TextViewRepresentable: UIViewRepresentable {
    let editor: Editor
    let title: String?
    let comments: CommentHighlightConfiguration
    let onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
    let onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
    let onAddComment: (@MainActor (String) -> Void)?
    let actions: KeyboardBarActions
    let configuration: KeyboardBarConfiguration
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
        accessory.update(actions: actions, configuration: configuration)
        accessory.textView = view
        if view.inputAccessoryView !== accessory {
          view.inputAccessoryView = accessory
          if view.isFirstResponder { view.reloadInputViews() }
        }
        view.traitOverrides[AccentTrait.self] = accent
        editor.setCommentHighlights(
          comments, onOpenCommentThreads: onOpenCommentThreads,
          onLinkedCommentIDsChange: onLinkedCommentIDsChange, onAddComment: onAddComment)
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
      editor.view.updateViewportView(view)
      return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
      view.textView = editor.textView
      editor.view.updateViewportView(view)
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
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if let error { Text(error).foregroundStyle(.red) }
        }
        .defaultFocus($urlFocused, true)
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
    }

    private func insert() {
      do {
        try save(label, destination)
        dismiss()
      } catch Formatting.FormattingError.invalidLink {
        self.error = String(
          localized: "Enter a complete web, email or phone link.", bundle: .module)
      } catch {
        self.error = String(
          localized: "The file changed. Cancel and select the text again.", bundle: .module)
      }
    }
  }
#endif
