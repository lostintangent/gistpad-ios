#if canImport(UIKit)
  import GistPadAccent
  import GistPadComments
  import SwiftUI
  import UIKit

  public struct MarkdownEditorView: View {
    public let session: DocumentSession
    private let insertPhoto: (@MainActor () -> Void)?
    private let canInsertPhoto: Bool
    private let intelligence: (@MainActor () -> Void)?
    private let comments: CommentHighlightConfiguration
    private let onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
    private let onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
    private let onAddComment: (@MainActor (String) -> Void)?
    @State private var linkRequest: LinkRequest?
    @State private var actionError: String?

    public init(
      session: DocumentSession,
      insertPhoto: (@MainActor () -> Void)? = nil,
      canInsertPhoto: Bool = false,
      intelligence: (@MainActor () -> Void)? = nil,
      comments: CommentHighlightConfiguration = .init(),
      onOpenCommentThreads: (@MainActor ([Int64]) -> Void)? = nil,
      onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)? = nil,
      onAddComment: (@MainActor (String) -> Void)? = nil
    ) {
      self.session = session
      self.insertPhoto = insertPhoto
      self.canInsertPhoto = canInsertPhoto
      self.intelligence = intelligence
      self.comments = comments
      self.onOpenCommentThreads = onOpenCommentThreads
      self.onLinkedCommentIDsChange = onLinkedCommentIDsChange
      self.onAddComment = onAddComment
    }

    public var body: some View {
      GeometryReader { _ in
        SourceTextView(
          session: session,
          comments: comments, onOpenCommentThreads: onOpenCommentThreads,
          onLinkedCommentIDsChange: onLinkedCommentIDsChange,
          onAddComment: onAddComment,
          actions: SourceToolbarActions(
            format: format, link: beginLink, indent: indent,
            photo: insertPhoto,
            intelligence: intelligence,
            dismiss: { session.textView.resignFirstResponder() }),
          configuration: SourceToolbarConfiguration(
            canFormat: session.canFormat,
            canInsertPhoto: canInsertPhoto && insertPhoto != nil,
            canUseIntelligence: session.isSettled && intelligence != nil)
        )
        .id(session.viewIdentity)
        .ignoresSafeArea([.container, .keyboard], edges: .vertical)
      }
      .overlay { SourceViewport(session: session).allowsHitTesting(false) }
      .sheet(
        item: $linkRequest,
        onDismiss: {
          if session.textView.window != nil, session.textView.isEditable {
            session.textView.becomeFirstResponder()
          }
        }
      ) { request in
        LinkEditor(label: request.label) { label, destination in
          if let edit = try MarkdownFormatting.edit(
            .link(label: label, destination: destination), in: request.source,
            selection: request.selection)
          {
            try session.apply(edit, generation: request.generation)
          }
        }
      }
      .alert(
        String(localized: "Couldn't Complete Action", bundle: .module),
        isPresented: Binding(
          get: { actionError != nil || session.inputError != nil },
          set: {
            if !$0 {
              actionError = nil
              session.inputError = nil
            }
          })
      ) {
        Button(String(localized: "OK", bundle: .module), role: .cancel) {
          actionError = nil
          session.inputError = nil
        }
      } message: {
        Text(actionError ?? session.inputError ?? "")
      }
    }

    private func format(_ command: MarkdownFormat) {
      do {
        if let edit = try MarkdownFormatting.edit(
          command, in: session.text, selection: session.textView.selectedRange)
        {
          try session.apply(edit, generation: session.generation)
        }
      } catch SourceEdit.MutationError.compositionActive {
        actionError = String(
          localized:
            "The source couldn't be formatted. Try again after composition or Writing Tools finishes.",
          bundle: .module)
      } catch {
        actionError = String(
          localized: "The source changed. Select the text again before formatting.", bundle: .module
        )
      }
    }

    private func beginLink() {
      let selection = session.textView.selectedRange
      guard session.canFormat, let label = try? SourceEdit.text(in: session.text, at: selection)
      else {
        actionError = String(
          localized: "Finish the current text edit, then select the link text again.",
          bundle: .module)
        return
      }
      linkRequest = LinkRequest(
        source: session.text, generation: session.generation, selection: selection, label: label)
    }

    private func indent(outdent: Bool) {
      do {
        try session.indent(outdent: outdent)
      } catch {
        actionError = String(
          localized: "Finish the current text edit, then select the lines again.", bundle: .module)
      }
    }

  }

  private struct SourceTextView: UIViewRepresentable {
    let session: DocumentSession
    let comments: CommentHighlightConfiguration
    let onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
    let onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
    let onAddComment: (@MainActor (String) -> Void)?
    let actions: SourceToolbarActions
    let configuration: SourceToolbarConfiguration
    @Environment(\.isPaneVisible) private var isPaneVisible
    @Environment(\.accent) private var accent

    func makeCoordinator() -> SourceAccessoryView {
      SourceAccessoryView(actions: actions)
    }

    func makeUIView(context: Context) -> SourceTextViewHost {
      let host = SourceTextViewHost(session: session)
      updateUIView(host, context: context)
      return host
    }

    func updateUIView(_ host: SourceTextViewHost, context: Context) {
      let accessory = context.coordinator
      host.configure { view in
        view.isHidden = !isPaneVisible
        view.isAccessibilityElement = isPaneVisible
        view.accessibilityElementsHidden = !isPaneVisible
        accessory.update(actions: actions, configuration: configuration)
        accessory.editor = view
        if view.inputAccessoryView !== accessory {
          view.inputAccessoryView = accessory
          if view.isFirstResponder { view.reloadInputViews() }
        }
        view.traitOverrides[AccentTrait.self] = accent
        session.setCommentHighlights(
          comments, onOpenCommentThreads: onOpenCommentThreads,
          onLinkedCommentIDsChange: onLinkedCommentIDsChange, onAddComment: onAddComment)
      }
    }

    static func dismantleUIView(_ host: SourceTextViewHost, coordinator: SourceAccessoryView) {
      host.dismantle()
    }
  }

  final class SourceTextViewHost: UIView {
    struct Reference {
      weak var host: SourceTextViewHost?
    }

    private let session: DocumentSession
    private var configuration: ((UITextView) -> Void)?
    private var isDismantled = false

    init(session: DocumentSession) {
      self.session = session
      super.init(frame: .zero)
      session.sourceHosts.append(Reference(host: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    func configure(_ configuration: @escaping (UITextView) -> Void) {
      guard !isDismantled else { return }
      self.configuration = configuration
      if ownsEditor { configuration(session.textView) }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard !isDismantled else { return }
      updateOwnership()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard window != nil, !isDismantled else { return }
      if session.sourceHost?.window == nil { updateOwnership() }
      guard session.sourceHost === self else { return }
      if !ownsEditor { adoptEditor() }
      if session.textView.frame != bounds { session.textView.frame = bounds }
      // Laying out now, inside any column animation, lets the keyboard capsule glide with the note.
      if let accessory = session.textView.inputAccessoryView, accessory.window != nil {
        accessory.setNeedsLayout()
        accessory.layoutIfNeeded()
      }
    }

    func dismantle() {
      isDismantled = true
      configuration = nil
      updateOwnership()
      guard session.sourceHost == nil, session.textView.superview === self else { return }
      session.setCommentHighlights(.init())
      session.textView.inputAccessoryView = nil
      session.textView.removeFromSuperview()
    }

    private var ownsEditor: Bool {
      session.sourceHost === self && session.textView.superview === self
    }

    private func updateOwnership() {
      session.sourceHosts.removeAll {
        $0.host == nil || $0.host?.isDismantled == true
      }
      // Re-entering an older native column must not supersede a newer live host.
      let owner = session.sourceHosts.last { $0.host?.window != nil }?.host
      guard session.sourceHost !== owner || owner?.ownsEditor == false else { return }
      session.sourceHost = owner
      owner?.adoptEditor()
    }

    private func adoptEditor() {
      guard window != nil, session.sourceHost === self, !isDismantled else { return }
      // SwiftUI owns this container, never the text view shared with another host.
      let editor = session.textView
      editor.frame = bounds
      editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      configuration?(editor)
      addSubview(editor)
    }
  }

  private struct SourceViewport: UIViewRepresentable {
    let session: DocumentSession

    func makeUIView(context: Context) -> SourceViewportView {
      let view = SourceViewportView()
      view.editor = session.textView
      session.sourceView.updateViewportView(view)
      return view
    }

    func updateUIView(_ view: SourceViewportView, context: Context) {
      view.editor = session.textView
      session.sourceView.updateViewportView(view)
    }
  }

  private final class SourceViewportView: UIView {
    weak var editor: UITextView?
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
      editor?.setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateChrome()
      editor?.setNeedsLayout()
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
      guard topEdge.view !== navigationBar || topEdge.scrollView !== editor else { return }
      topEdge.view?.removeInteraction(topEdge)
      topEdge.scrollView = editor
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
              .tint(.primary)
              .accessibilityLabel(String(localized: "Cancel", bundle: .module))
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm) { insert() }
              .buttonStyle(.glassProminent)
              .tint(Color(uiColor: .label))
              .accessibilityLabel(String(localized: "Insert Link", bundle: .module))
              .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }

    private func insert() {
      do {
        try save(label, destination)
        dismiss()
      } catch MarkdownFormatting.FormattingError.invalidLink {
        self.error = String(
          localized: "Enter a complete web, email or phone link.", bundle: .module)
      } catch {
        self.error = String(
          localized:
            "The source changed while this sheet was open. Cancel and select the text again.",
          bundle: .module)
      }
    }
  }
#endif
