import Comments
import Editor
import Screens
import Model
import Observation
import OSLog
import SwiftUI

/// Comments for the open gist: one in-memory `CommentsModel`, dropped when another gist opens.
@MainActor
@Observable
final class CommentsPresentation {
  struct Scope: Hashable {
    let accountID: UUID
    let gistID: String
  }

  /// What `track(_:)` reads, so a file's tracking restarts when any of it changes.
  struct Tracking: Hashable {
    let editorID: UUID
    let gistID: String?
    let knownTotal: Int?
    let isReady: Bool
    let allowsComments: Bool
    let showsInlineComments: Bool
  }

  var isPresented = false
  private(set) var model: CommentsModel?
  var selectedThreadID: Int64?
  var passageRevealRevision: UInt64 = 0
  var threadRevealRevision: UInt64 = 0
  var editorLinkedThreadIDs: Set<Int64>?
  var previewLinkedThreadIDs: Set<Int64>?
  var fileMode: FileMode = .preview
  var detent = PresentationDetent.medium
  var isComposerFocused = false
  var preparationFailure: String?
  var overlappingThreadIDs: [Int64] = []
  var sidebarBeforeOpening: NavigationSplitViewVisibility?
  var requestedRowID: String?
  private(set) var editorID: UUID?
  private(set) var scope: Scope?
  @ObservationIgnored let app: GistPadModel
  @ObservationIgnored private var fileEditor: GistFileEditor?
  @ObservationIgnored private var afterDismiss: (() -> Void)?
  @ObservationIgnored private var returnsToEditing = false

  init(app: GistPadModel) {
    self.app = app
  }

  /// The threads whose passages the current file mode links.
  var linkedThreadIDs: Set<Int64>? {
    fileMode == .edit ? editorLinkedThreadIDs : previewLinkedThreadIDs
  }

  private var showsInlineComments: Bool {
    app.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true
  }

  static func supports(_ file: GistFile) -> Bool {
    guard let gist = file.gist else { return false }
    return !gist.isDailyNote && !file.isDeletedOnGitHub
  }

  func matches(_ file: GistFile) -> Bool {
    guard let gistID = file.gist?.id else { return false }
    return scope == .init(accountID: file.accountID, gistID: gistID)
  }

  func activate(_ next: GistFileEditor) {
    let nextScope = Self.supports(next.file)
      ? next.file.gist.map { Scope(accountID: next.file.accountID, gistID: $0.id) } : nil
    guard editorID != next.editor.id || scope != nextScope else { return }
    if scope != nextScope {
      hide()
      model = nil
    }
    scope = nextScope
    fileEditor = next
    editorID = next.editor.id
    editorLinkedThreadIDs = nil
    previewLinkedThreadIDs = nil
    preparationFailure = nil
  }

  func tracking(_ fileEditor: GistFileEditor) -> Tracking {
    .init(
      editorID: fileEditor.editor.id, gistID: fileEditor.file.gist?.id,
      knownTotal: fileEditor.file.gist?.commentCount, isReady: isReady(for: fileEditor.file),
      allowsComments: Self.supports(fileEditor.file), showsInlineComments: showsInlineComments)
  }

  /// Follows the open file, loading its comments when passages show inline.
  func track(_ fileEditor: GistFileEditor) async {
    guard isReady(for: fileEditor.file) else { return }
    activate(fileEditor)
    guard showsInlineComments, editorID == fileEditor.editor.id else { return }
    await prepare()?.refresh()
  }

  /// The file's passage highlights in one mode, and what tapping, linking and adding one does.
  func highlights(
    for fileEditor: GistFileEditor, origin: FileMode
  ) -> (configuration: CommentHighlightConfiguration, actions: CommentHighlightActions?) {
    guard Self.supports(fileEditor.file) else { return (.init(), nil) }
    var configuration = CommentHighlightConfiguration()
    if matches(fileEditor.file), let model {
      configuration = .init(
        quotes: model.threads.compactMap(\.quotedPassage), selectedThreadID: selectedThreadID,
        revealRevision: passageRevealRevision, showsInlineComments: showsInlineComments)
    }
    let isCurrent = { self.editorID == fileEditor.editor.id }
    let actions = CommentHighlightActions(
      open: { ids in
        guard isCurrent() else { return }
        if ids.count == 1, let id = ids.first {
          self.open(for: fileEditor, origin: origin, threadID: id)
        } else {
          self.fileMode = origin
          self.overlappingThreadIDs = ids
        }
      },
      linked: { ids in
        guard isCurrent() else { return }
        if origin == .preview { self.previewLinkedThreadIDs = ids } else { self.editorLinkedThreadIDs = ids }
      },
      add: { selection in
        guard isCurrent() else { return }
        self.open(for: fileEditor, origin: origin, quote: selection)
      })
    return (configuration, actions)
  }

  func open(
    for next: GistFileEditor, origin: FileMode? = nil,
    threadID: Int64? = nil, quote: String? = nil
  ) {
    guard editorID == next.editor.id, Self.supports(next.file) else { return }
    let opening = !isPresented
    if opening {
      returnsToEditing = next.editor.isEditing
      next.editor.endEditing()
      fileMode = origin ?? (returnsToEditing ? .edit : next.mode)
      if fileMode == .split { fileMode = .preview }
    } else if let origin {
      fileMode = origin
    }
    if !next.details.isOwned { fileMode = .preview }
    detent = quote == nil ? .medium : .large
    selectedThreadID = threadID
    preparationFailure = nil
    isPresented = true
    let filename = next.file.filename
    Task {
      guard let model = await prepare() else { return }
      if let quote {
        model.beginQuote(quote, filename: filename)
        isComposerFocused = true
      }
      if model.comments == nil {
        await model.refresh()
      } else if opening {
        Task { await model.refresh() }
      }
      if threadID != nil { threadRevealRevision &+= 1 }
    }
  }

  func retryOpening() {
    preparationFailure = nil
    Task { await prepare()?.refresh() }
  }

  func hide() {
    isPresented = false
    selectedThreadID = nil
    overlappingThreadIDs = []
    isComposerFocused = false
  }

  func focusComposer() {
    detent = .large
    isComposerFocused = true
  }

  /// Shows a thread's passage in the file, out from under the keyboard and a full-height sheet.
  func revealPassage(_ id: Int64) {
    selectedThreadID = id
    isComposerFocused = false
    detent = .medium
    passageRevealRevision &+= 1
  }

  func didDismiss() {
    guard !isPresented else { return }
    hide()
    if let afterDismiss {
      self.afterDismiss = nil
      afterDismiss()
      return
    }
    let resumesEditing = returnsToEditing
    returnsToEditing = false
    if resumesEditing { fileEditor?.editor.focus() }
  }

  func performAfterClosing(_ action: @escaping () -> Void) {
    guard isPresented else { action(); return }
    afterDismiss = action
    hide()
  }

  func reset() {
    hide()
    afterDismiss = nil
    returnsToEditing = false
    model = nil
    fileEditor = nil
    scope = nil
    editorID = nil
    requestedRowID = nil
    editorLinkedThreadIDs = nil
    previewLinkedThreadIDs = nil
  }

  private func isReady(for file: GistFile) -> Bool {
    app.account?.id == file.accountID && !app.phase.isChangingAccount
  }

  private func prepare() async -> CommentsModel? {
    if let model { return model }
    guard let scope, let gist = fileEditor?.file.gist else { return nil }
    do {
      let created = try await app.comments(for: gist)
      guard self.scope == scope else { return nil }
      if let model { return model }
      model = created
      return created
    } catch {
      guard self.scope == scope else { return nil }
      preparationFailure = error.localizedDescription
      Logger(subsystem: "dev.gistpad.GistPad", category: "Comments")
        .error("Comments preparation failed: \(String(reflecting: type(of: error)), privacy: .public)")
      return nil
    }
  }
}
