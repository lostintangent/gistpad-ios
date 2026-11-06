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

  var isPresented = false
  private(set) var conversation: CommentsModel?
  var selectedRootID: Int64?
  var revealRevision: UInt64 = 0
  var threadRevealRevision: UInt64 = 0
  var sourceLinkedIDs: Set<Int64>?
  var previewLinkedIDs: Set<Int64>?
  var fileMode: FileMode = .preview
  var detent = PresentationDetent.medium
  var isComposerFocused = false
  var preparationFailure: String?
  var overlappingIDs: [Int64] = []
  var sidebarBeforeOpening: NavigationSplitViewVisibility?
  var requestedRowID: String?
  private(set) var editorID: UUID?
  private(set) var scope: Scope?
  @ObservationIgnored let model: GistPadModel
  @ObservationIgnored private var fileEditor: GistFileEditor?
  @ObservationIgnored private var afterDismiss: (() -> Void)?
  @ObservationIgnored private var returnsToEditing = false

  init(model: GistPadModel) {
    self.model = model
  }

  static func supports(_ file: GistFile) -> Bool {
    guard let gist = file.gist else { return false }
    return !gist.isDailyNote && !file.isRecovery
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
      conversation = nil
    }
    scope = nextScope
    fileEditor = next
    editorID = next.editor.id
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
    preparationFailure = nil
  }

  func prepareAnnotations(for next: GistFileEditor, showsInline: Bool) async {
    guard showsInline, editorID == next.editor.id else { return }
    await prepare()?.refresh()
  }

  func open(
    for next: GistFileEditor, origin: FileMode? = nil,
    rootID: Int64? = nil, quote: String? = nil
  ) {
    guard editorID == next.editor.id, Self.supports(next.file) else { return }
    let opening = !isPresented
    if opening {
      returnsToEditing = next.editor.textView.isFirstResponder
      if returnsToEditing { next.editor.textView.resignFirstResponder() }
      fileMode = origin ?? (returnsToEditing || next.editor.isEditing ? .edit : next.mode)
      if fileMode == .split { fileMode = .preview }
    } else if let origin {
      fileMode = origin
    }
    if !next.details.access.canEdit { fileMode = .preview }
    detent = quote == nil ? .medium : .large
    selectedRootID = rootID
    preparationFailure = nil
    isPresented = true
    let filename = next.draft.filename
    Task {
      guard let conversation = await prepare() else { return }
      if let quote {
        conversation.beginQuote(quote, filename: filename)
        isComposerFocused = true
      }
      if conversation.comments == nil {
        await conversation.refresh()
      } else if opening {
        Task { await conversation.refresh() }
      }
      if rootID != nil { threadRevealRevision &+= 1 }
    }
  }

  func retryOpening() {
    preparationFailure = nil
    Task { await prepare()?.refresh() }
  }

  func hide() {
    isPresented = false
    selectedRootID = nil
    overlappingIDs = []
    isComposerFocused = false
  }

  /// Shows a thread's passage in the file, out from under the keyboard and a full-height sheet.
  func revealPassage(_ id: Int64) {
    selectedRootID = id
    isComposerFocused = false
    detent = .medium
    revealRevision &+= 1
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
    guard resumesEditing, let fileEditor, fileEditor.editor.canFormat,
      !fileEditor.editor.textView.isHidden, fileEditor.editor.textView.window != nil
    else { return }
    if !fileEditor.editor.textView.becomeFirstResponder() {
      fileEditor.editor.inputError = String(localized: "Tap the file to resume writing.")
    }
  }

  func performAfterClosing(_ action: @escaping () -> Void) {
    guard isPresented else { action(); return }
    afterDismiss = action
    hide()
  }

  func discard(gistID: String, accountID: UUID) {
    if scope == .init(accountID: accountID, gistID: gistID) { reset() }
  }

  func reset() {
    hide()
    afterDismiss = nil
    returnsToEditing = false
    conversation = nil
    fileEditor = nil
    scope = nil
    editorID = nil
    requestedRowID = nil
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
  }

  private func prepare() async -> CommentsModel? {
    if let conversation { return conversation }
    guard let scope, let gist = fileEditor?.file.gist else { return nil }
    do {
      let services = try await model.comments(accountID: scope.accountID)
      guard self.scope == scope else { return nil }
      if let conversation { return conversation }
      let created = CommentsModel(
        gistID: scope.gistID, userID: services.userID, gistOwnerID: gist.owner?.id,
        remote: services.remote)
      conversation = created
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
