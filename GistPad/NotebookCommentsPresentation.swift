import GistPadComments
import GistPadEditor
import GistPadInterface
import OSLog
import Observation
import SwiftUI

@MainActor
@Observable
final class NotebookCommentsPresentation {
  var isPresented = false
  var conversation: CommentConversationController?
  var selectedRootID: Int64?
  var revealRevision: UInt64 = 0
  var threadRevealRevision: UInt64 = 0
  var sourceLinkedIDs: Set<Int64>?
  var previewLinkedIDs: Set<Int64>?
  var documentMode: NoteMode = .reading
  var detent = PresentationDetent.medium
  var focusRequest: UInt64 = 0
  var preparationFailure: String?
  var errorMessage: String?
  var overlappingIDs: [Int64] = []
  var sidebarBeforeOpening: NavigationSplitViewVisibility?
  var requestedRowID: String?
  private(set) var sessionID: UUID?
  @ObservationIgnored private let notebook: NotebookModel
  @ObservationIgnored private var provider: NotebookCommentProvider?
  @ObservationIgnored private var controller: NotebookSessionController?
  private var activeScope: CommentConversationScope?
  @ObservationIgnored private var requestID = UUID()
  @ObservationIgnored private var pendingQuote: CapturedCommentQuote?
  @ObservationIgnored private var pendingRootID: Int64?
  @ObservationIgnored private var afterDismiss: (() -> Void)?
  @ObservationIgnored private var returnsToEditing = false
  @ObservationIgnored private var awaitsDismissal = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Comments")

  init(notebook: NotebookModel, provider: NotebookCommentProvider? = nil) {
    self.notebook = notebook
    self.provider = provider
  }

  static func supports(_ document: NotebookDocument) -> Bool {
    guard let gist = document.gist else { return false }
    return !gist.isDailyNote && !document.isRecovery
  }

  func matches(_ document: NotebookDocument) -> Bool {
    guard let gistID = document.gist?.id else { return false }
    return activeScope == .init(accountID: document.accountID, gistID: gistID)
  }

  func activate(_ next: NotebookSessionController) {
    let scope = Self.supports(next.document)
      ? next.document.gist.map {
        CommentConversationScope(accountID: next.document.accountID, gistID: $0.id)
      } : nil
    guard sessionID != next.session.viewIdentity || activeScope != scope else { return }
    if activeScope != scope {
      hide()
      conversation = nil
    }
    activeScope = scope
    controller = next
    sessionID = next.session.viewIdentity
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
    preparationFailure = nil
    requestID = UUID()
    if isPresented { loadForOpening(next) }
  }

  func prepareAnnotations(for next: NotebookSessionController, showsInline: Bool) async {
    guard showsInline, isCurrent(next), Self.supports(next.document) else { return }
    do {
      let model = try await preparedConversation(for: next.document)
      guard isCurrent(next) else { return }
      conversation = model
      await model.load()
    } catch {
      guard isCurrent(next) else { return }
      preparationFailure = NotebookModel.message(for: error)
      logger.error("Comments preparation failed: \(String(reflecting: type(of: error)), privacy: .public)")
    }
  }

  func open(
    for next: NotebookSessionController, origin: NoteMode? = nil,
    rootID: Int64? = nil, quote: String? = nil
  ) {
    guard isCurrent(next), Self.supports(next.document) else { return }
    guard !next.session.isComposing, !next.session.writingToolsActive,
      next.session.textView.markedTextRange == nil else {
      errorMessage = String(
        localized: "Finish composition or Writing Tools before opening Comments.")
      return
    }
    if !isPresented {
      awaitsDismissal = true
      returnsToEditing = next.session.textView.isFirstResponder
      if returnsToEditing { next.session.textView.resignFirstResponder() }
      documentMode = origin ?? (returnsToEditing || next.session.isEditing ? .source : next.mode)
      if documentMode == .split { documentMode = .reading }
    } else if let origin {
      documentMode = origin
    }
    if !next.document.chrome.access.canEdit { documentMode = .reading }
    pendingQuote = quote.map { .init(filename: next.draft.filename, text: $0) }
    pendingRootID = rootID
    detent = quote == nil ? .medium : .large
    preparationFailure = nil
    isPresented = true
    loadForOpening(next)
  }

  func retryOpening() {
    guard isPresented, let controller, isCurrent(controller) else { return }
    preparationFailure = nil
    loadForOpening(controller)
  }

  private func loadForOpening(_ next: NotebookSessionController) {
    let request = UUID()
    requestID = request
    Task {
      do {
        let model = try await preparedConversation(for: next.document)
        guard requestID == request, isCurrent(next), isPresented else { return }
        conversation = model
        applyPendingContext()
        await model.load()
        guard requestID == request, isCurrent(next), isPresented else { return }
        applyPendingContext()
      } catch {
        guard requestID == request, isCurrent(next), isPresented else { return }
        preparationFailure = NotebookModel.message(for: error)
        logger.error("Comments opening failed: \(String(reflecting: type(of: error)), privacy: .public)")
      }
    }
  }

  func applyPendingContext() {
    guard let conversation, conversation.isPrepared else { return }
    if let quote = pendingQuote {
      conversation.beginQuote(quote)
      if conversation.composer.problem == nil {
        pendingQuote = nil
        focusRequest &+= 1
      }
    }
    if let id = pendingRootID, conversation.comments != nil {
      pendingRootID = nil
      guard conversation.threads.contains(where: { $0.id == id }) else {
        preparationFailure = CommentConversationProblem.missingTarget(id).interfaceDescription
        return
      }
      selectedRootID = id
      threadRevealRevision &+= 1
    }
  }

  func hide() {
    isPresented = false
    selectedRootID = nil
    overlappingIDs = []
    pendingRootID = nil
    pendingQuote = nil
    focusRequest = 0
    requestID = UUID()
  }

  func didDismiss() {
    guard !isPresented else { return }
    hide()
    awaitsDismissal = false
    if let afterDismiss {
      self.afterDismiss = nil
      afterDismiss()
      return
    }
    guard returnsToEditing, let controller, isCurrent(controller),
      controller.session.canFormat, !controller.session.textView.isHidden,
      controller.session.textView.window != nil else { return }
    returnsToEditing = false
    if !controller.session.textView.becomeFirstResponder() {
      controller.session.inputError = String(localized: "Tap the note to resume writing.")
    }
  }

  func performAfterClosing(_ action: @escaping () -> Void) {
    guard isPresented || awaitsDismissal else { action(); return }
    let identity = sessionID
    let request = requestID
    Task { [self] in
      if let conversation, conversation.isPrepared, !(await conversation.flushDraft()) { return }
      guard sessionID == identity, let controller, isCurrent(controller) else { return }
      guard !isPresented || requestID == request else { return }
      guard awaitsDismissal else { action(); return }
      afterDismiss = { [weak self] in
        guard let self, self.sessionID == identity,
          let controller = self.controller, self.isCurrent(controller) else { return }
        action()
      }
      hide()
    }
  }

  func close() async {
    let identity = sessionID
    let request = requestID
    let model = conversation
    if let model, model.isPrepared, !(await model.flushDraft()) { return }
    guard sessionID == identity, requestID == request, conversation === model else {
      logger.debug("A newer conversation superseded the Comments close request.")
      return
    }
    hide()
  }

  func flushDrafts() async -> Bool {
    guard let provider else { return true }
    return await provider.flushDrafts()
  }

  func discard(gistID: String, accountID: UUID) async throws {
    if activeScope == .init(accountID: accountID, gistID: gistID) { reset() }
    try await provider?.discard(gistID: gistID, accountID: accountID)
  }

  func reset() {
    hide()
    afterDismiss = nil
    returnsToEditing = false
    conversation = nil
    controller = nil
    activeScope = nil
    sessionID = nil
    requestedRowID = nil
    sourceLinkedIDs = nil
    previewLinkedIDs = nil
  }

  private func preparedConversation(for document: NotebookDocument) async throws
    -> CommentConversationController {
    if provider == nil { provider = try NotebookCommentProvider(notebook: notebook) }
    guard let provider else { preconditionFailure("A comments provider must be prepared.") }
    return try await provider.conversation(for: document)
  }

  private func isCurrent(_ candidate: NotebookSessionController) -> Bool {
    sessionID == candidate.session.viewIdentity
      && notebook.account?.id == candidate.draft.accountID
      && notebook.pendingAccount == nil && !notebook.isSigningIn && !notebook.isSigningOut
      && notebook.presentedDocument?.refersToSameFile(as: candidate.document) == true
  }
}
