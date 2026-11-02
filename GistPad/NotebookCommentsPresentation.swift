import GistPadComments
import GistPadEditor
import GistPadInterface
import OSLog
import Observation
import SwiftUI

/// Comments for the open gist: one in-memory `CommentsModel`, dropped when another gist opens.
@MainActor
@Observable
final class NotebookCommentsPresentation {
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
  var documentMode: NoteMode = .reading
  var detent = PresentationDetent.medium
  var isComposerFocused = false
  var preparationFailure: String?
  var overlappingIDs: [Int64] = []
  var sidebarBeforeOpening: NavigationSplitViewVisibility?
  var requestedRowID: String?
  private(set) var sessionID: UUID?
  private(set) var scope: Scope?
  @ObservationIgnored private let notebook: NotebookModel
  @ObservationIgnored private var controller: NotebookSessionController?
  @ObservationIgnored private var afterDismiss: (() -> Void)?
  @ObservationIgnored private var returnsToEditing = false

  init(notebook: NotebookModel) {
    self.notebook = notebook
  }

  static func supports(_ document: NotebookDocument) -> Bool {
    guard let gist = document.gist else { return false }
    return !gist.isDailyNote && !document.isRecovery
  }

  func matches(_ document: NotebookDocument) -> Bool {
    guard let gistID = document.gist?.id else { return false }
    return scope == .init(accountID: document.accountID, gistID: gistID)
  }

  func activate(_ next: NotebookSessionController) {
    let nextScope = Self.supports(next.document)
      ? next.document.gist.map { Scope(accountID: next.document.accountID, gistID: $0.id) } : nil
    guard sessionID != next.session.viewIdentity || scope != nextScope else { return }
    if scope != nextScope {
      hide()
      conversation = nil
    }
    scope = nextScope
    controller = next
    sessionID = next.session.viewIdentity
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
    preparationFailure = nil
  }

  func prepareAnnotations(for next: NotebookSessionController, showsInline: Bool) async {
    guard showsInline, sessionID == next.session.viewIdentity else { return }
    await prepare()?.refresh()
  }

  func open(
    for next: NotebookSessionController, origin: NoteMode? = nil,
    rootID: Int64? = nil, quote: String? = nil
  ) {
    guard sessionID == next.session.viewIdentity, Self.supports(next.document) else { return }
    let opening = !isPresented
    if opening {
      returnsToEditing = next.session.textView.isFirstResponder
      if returnsToEditing { next.session.textView.resignFirstResponder() }
      documentMode = origin ?? (returnsToEditing || next.session.isEditing ? .source : next.mode)
      if documentMode == .split { documentMode = .reading }
    } else if let origin {
      documentMode = origin
    }
    if !next.document.chrome.access.canEdit { documentMode = .reading }
    detent = quote == nil ? .medium : .large
    selectedRootID = rootID
    preparationFailure = nil
    isPresented = true
    let filename = next.draft.filename
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

  /// Shows a thread's passage in the note, out from under the keyboard and a full-height sheet.
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
    guard resumesEditing, let controller, controller.session.canFormat,
      !controller.session.textView.isHidden, controller.session.textView.window != nil
    else { return }
    if !controller.session.textView.becomeFirstResponder() {
      controller.session.inputError = String(localized: "Tap the note to resume writing.")
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
    controller = nil
    scope = nil
    sessionID = nil
    requestedRowID = nil
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
  }

  private func prepare() async -> CommentsModel? {
    if let conversation { return conversation }
    guard let scope, let gist = controller?.document.gist else { return nil }
    do {
      let services = try await notebook.commentServices(accountID: scope.accountID)
      guard self.scope == scope else { return nil }
      if let conversation { return conversation }
      let model = CommentsModel(
        gistID: scope.gistID, userID: services.userID, gistOwnerID: gist.owner?.id,
        remote: services.remote)
      conversation = model
      return model
    } catch {
      guard self.scope == scope else { return nil }
      preparationFailure = NotebookModel.message(for: error)
      Logger(subsystem: "dev.gistpad.GistPad", category: "Comments")
        .error("Comments preparation failed: \(String(reflecting: type(of: error)), privacy: .public)")
      return nil
    }
  }
}
