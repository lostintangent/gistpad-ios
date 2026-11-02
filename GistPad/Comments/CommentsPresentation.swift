import GistPadComments
import GistPadEditor
import GistPadInterface
import OSLog
import Observation
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
  private(set) var sessionID: UUID?
  private(set) var scope: Scope?
  @ObservationIgnored let library: Library
  @ObservationIgnored private var session: FileSession?
  @ObservationIgnored private var afterDismiss: (() -> Void)?
  @ObservationIgnored private var returnsToEditing = false

  init(library: Library) {
    self.library = library
  }

  static func supports(_ file: File) -> Bool {
    guard let gist = file.gist else { return false }
    return !gist.isDailyNote && !file.isRecovery
  }

  func matches(_ file: File) -> Bool {
    guard let gistID = file.gist?.id else { return false }
    return scope == .init(accountID: file.accountID, gistID: gistID)
  }

  func activate(_ next: FileSession) {
    let nextScope = Self.supports(next.file)
      ? next.file.gist.map { Scope(accountID: next.file.accountID, gistID: $0.id) } : nil
    guard sessionID != next.editor.id || scope != nextScope else { return }
    if scope != nextScope {
      hide()
      conversation = nil
    }
    scope = nextScope
    session = next
    sessionID = next.editor.id
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
    preparationFailure = nil
  }

  func prepareAnnotations(for next: FileSession, showsInline: Bool) async {
    guard showsInline, sessionID == next.editor.id else { return }
    await prepare()?.refresh()
  }

  func open(
    for next: FileSession, origin: FileMode? = nil,
    rootID: Int64? = nil, quote: String? = nil
  ) {
    guard sessionID == next.editor.id, Self.supports(next.file) else { return }
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
    guard resumesEditing, let session, session.editor.canFormat,
      !session.editor.textView.isHidden, session.editor.textView.window != nil
    else { return }
    if !session.editor.textView.becomeFirstResponder() {
      session.editor.inputError = String(localized: "Tap the file to resume writing.")
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
    session = nil
    scope = nil
    sessionID = nil
    requestedRowID = nil
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
  }

  private func prepare() async -> CommentsModel? {
    if let conversation { return conversation }
    guard let scope, let gist = session?.file.gist else { return nil }
    do {
      let services = try await library.comments(accountID: scope.accountID)
      guard self.scope == scope else { return nil }
      if let conversation { return conversation }
      let model = CommentsModel(
        gistID: scope.gistID, userID: services.userID, gistOwnerID: gist.owner?.id,
        remote: services.remote)
      conversation = model
      return model
    } catch {
      guard self.scope == scope else { return nil }
      preparationFailure = error.localizedDescription
      Logger(subsystem: "dev.gistpad.GistPad", category: "Comments")
        .error("Comments preparation failed: \(String(reflecting: type(of: error)), privacy: .public)")
      return nil
    }
  }
}
