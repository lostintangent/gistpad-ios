import Foundation
import GistPadEditor
import GistPadInterface
import GistPadSync
import OSLog
import Observation

enum NotebookEditError: Error {
  case localPersistenceFailed
  case invalidCommittedEdit
  case photoServicesUnavailable
}

@MainActor
@Observable
final class NotebookSessionController {
  private(set) var document: NotebookDocument
  let session: DocumentSession
  private(set) var draft: DraftSnapshot
  private(set) var saveState: NoteSaveState
  private(set) var isPublishing = false
  private(set) var isPerformingDestructiveAction = false
  private(set) var metadataError: String?
  private(set) var isApplyingDurableEdit = false
  private(set) var remoteInspectionError: String?
  private(set) var isInspectingRemote = false
  var mode: NoteMode = .reading
  @ObservationIgnored private let notebook: NotebookModel
  @ObservationIgnored private var persistence: Task<Bool, Never>?
  @ObservationIgnored private var autosaveTask: Task<Void, Never>?
  @ObservationIgnored private var scheduledAutosave: AutosaveRequest?
  @ObservationIgnored private var isForeground = false
  @ObservationIgnored private var didRequestCreationFocus = false
  @ObservationIgnored private let autosaveDelay: Duration
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Document")

  init(
    document: NotebookDocument, draft: DraftSnapshot, notebook: NotebookModel,
    autosaveDelay: Duration = .seconds(5)
  ) {
    var initialDocument = document
    if notebook.account?.id == draft.accountID {
      initialDocument.chrome = notebook.chrome(gist: document.gist, draft: draft)
    }
    self.document = initialDocument
    self.draft = draft
    self.notebook = notebook
    self.autosaveDelay = autosaveDelay
    session = DocumentSession(
      documentID: document.id, text: draft.text, generation: draft.generation)
    saveState = NotebookModel.interfaceSaveState(draft.state)
    if document.isRecovery {
      saveState = .publicationBlocked(
        message: String(
          localized: "The original note is unavailable. This local copy is preserved for recovery.")
      )
    }
    if draft.baseContent == nil { mode = .source }
    session.textView.isEditable = self.document.chrome.access.canEdit
    session.onSourceChange = { [weak self] text, generation in
      self?.persist(text: text, generation: generation)
    }
  }

  var canMutate: Bool {
    document.chrome.access.canEdit && !session.isComposing && !session.writingToolsActive
      && !isPerformingDestructiveAction
      && !isApplyingDurableEdit
  }

  func requestCreationFocus() {
    guard document.opensForEditing, !didRequestCreationFocus, canMutate else { return }
    didRequestCreationFocus = true
    mode = .source
    session.requestFocusAtEnd()
  }

  struct AutosaveRequest: Equatable {
    let generation: UInt64
    let eligible: Bool
  }

  var autosaveRequest: AutosaveRequest {
    let stateAllowsAutosave: Bool
    switch draft.state {
    case .savedLocally, .offline, .reconnect: stateAllowsAutosave = true
    default: stateAllowsAutosave = false
    }
    return AutosaveRequest(
      generation: session.generation,
      eligible: autosaveAllowed && !isPublishing && saveState == .savedLocally
        && stateAllowsAutosave && hasUnpublishedChanges)
  }

  private var autosaveAllowed: Bool {
    isForeground && notebook.account?.id == draft.accountID && notebook.pendingAccount == nil
      && notebook.library.loadState == .ready
      && notebook.account?.preferences.isAutoSaveEnabled == true
      && canMutate && session.textView.markedTextRange == nil
      && !document.isRecovery && !draft.autosavePaused && draft.attemptedGeneration == nil
  }

  @discardableResult
  func updateAutosave(isForeground: Bool) -> Task<Void, Never>? {
    self.isForeground = isForeground
    let request = autosaveRequest
    guard request != scheduledAutosave else { return autosaveTask }
    scheduledAutosave = request
    autosaveTask?.cancel()
    autosaveTask = nil
    guard request.eligible else { return nil }
    autosaveTask = Task { [weak self, autosaveDelay] in
      do {
        try await Task.sleep(for: autosaveDelay)
        guard let self, !Task.isCancelled, autosaveRequest == request else { return }
        autosaveTask = nil
        await publish(reason: .autosave)
      } catch is CancellationError {
        return
      } catch {
        self?.logger.error(
          "Autosave delay failed: \(String(reflecting: type(of: error)), privacy: .public)")
      }
    }
    return autosaveTask
  }

  func refreshMetadata(gist: Gist? = nil) async throws {
    let current = try await notebook.draftSnapshot(id: draft.id, accountID: draft.accountID)
    if current.generation >= draft.generation { draft = current }
    document.draft = draft
    document.filename = draft.filename
    if let gist { document.gist = gist }
    document.chrome = notebook.chrome(gist: document.gist, draft: draft)
    if let id = current.gistID, notebook.deletedGistIDs.contains(id) { markRecovery() }
    session.textView.isEditable =
      document.chrome.access.canEdit && !isPerformingDestructiveAction && !isApplyingDurableEdit
  }

  func markRecovery() {
    document.isRecovery = true
    document.libraryRowID = draft.id.uuidString
    saveState = .publicationBlocked(
      message: String(
        localized: "The original note is unavailable. This local copy is preserved for recovery."))
  }

  func inspectRemoteChanges() async {
    guard !isInspectingRemote, !isPublishing, canMutate, !document.isRecovery,
      draft.gistID != nil, draft.attemptedGeneration == nil,
      notebook.account?.id == draft.accountID, notebook.pendingAccount == nil
    else { return }
    if case .conflict = draft.state { return }
    isInspectingRemote = true
    defer { isInspectingRemote = false }
    guard await waitForLocalSave() else { return }
    let generation = session.generation
    do {
      guard
        case .review(let inspected) = try await notebook.perform(
          .inspectRemote(draftID: draft.id, generation: generation))
      else { throw NotebookActionError.staleReview }
      let current = try await notebook.draftSnapshot(id: draft.id, accountID: draft.accountID)
      guard current.generation == session.generation else { return }
      draft = current
      if case .conflict = inspected.state { saveState = .remoteChange }
      remoteInspectionError = nil
    } catch is CancellationError {
      return
    } catch DraftError.staleGeneration {
      return
    } catch {
      logger.error(
        "Remote inspection failed: \(String(reflecting: type(of: error)), privacy: .public)")
      remoteInspectionError = NotebookModel.message(for: error)
    }
  }

  func adoptPresentation(_ incoming: NotebookDocument) {
    guard incoming.accountID == draft.accountID,
      incoming.gist?.id == document.gist?.id, incoming.filename == draft.filename
    else { return }
    document.libraryRowID = incoming.libraryRowID
    document.opensForEditing = incoming.opensForEditing
    if let gist = incoming.gist { document.gist = gist }
    document.chrome = notebook.chrome(gist: document.gist, draft: draft)
  }

  var hasUnpublishedChanges: Bool {
    guard let base = draft.baseContent else { return true }
    return !session.text.utf8.elementsEqual(base.utf8) || draft.attemptedGeneration != nil
  }

  func savedLinks() throws -> DocumentLinks? {
    guard !document.isRecovery, let gist = document.gist, draft.gistID != nil,
      gist.files[draft.filename] != nil
    else { return nil }
    return try DocumentLinks(gist: gist, filename: draft.filename, draft: draft)
  }

  func refreshPublicationMetadata() async throws {
    guard let gist = try await notebook.adoptPublication(draft) else {
      throw DocumentLinkError.notPublished
    }
    document.gist = gist
    document.draft = draft
    document.chrome = notebook.chrome(gist: gist, draft: draft)
    metadataError = nil
  }

  func reviewContext() throws -> NotebookReviewContext {
    let review = try NotebookReviewContext(draft: draft)
    guard session.generation == draft.generation,
      session.text.utf8.elementsEqual(draft.text.utf8)
    else { throw NotebookActionError.staleReview }
    return review
  }

  func refreshReview(_ review: NotebookReviewContext) async throws -> NotebookReviewContext {
    guard await waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
    guard case .review(let refreshed) = try await notebook.perform(.refreshConflict(review)) else {
      throw NotebookActionError.staleReview
    }
    guard session.generation == refreshed.generation else { throw NotebookActionError.staleReview }
    draft = refreshed
    saveState = .remoteChange
    return try NotebookReviewContext(draft: refreshed)
  }

  func applyReview(_ review: NotebookReviewContext, text: String) async throws {
    guard review.matches(draft), session.generation == review.draft.generation else {
      throw NotebookActionError.staleReview
    }
    let changed = !text.utf8.elementsEqual(session.text.utf8)
    guard !changed || session.generation < UInt64.max else { throw DraftError.staleGeneration }
    let generation = session.generation + (changed ? 1 : 0)
    try await commitMutation(
      SourceMutation(
        range: NSRange(location: 0, length: session.text.utf16.count),
        expected: session.text, replacement: text),
      expectedGeneration: review.draft.generation
    ) {
      guard
        case .review(let resolved) = try await notebook.perform(
          .resolveConflict(review, text: text, generation: generation))
      else {
        throw NotebookActionError.staleReview
      }
      return resolved
    }
  }

  func beginDestructiveAction() throws {
    guard canMutate, !isPublishing else { throw NotebookActionError.publicationInProgress }
    isPerformingDestructiveAction = true
    session.textView.isEditable = false
  }

  func endDestructiveAction() {
    isPerformingDestructiveAction = false
    session.textView.isEditable = document.chrome.access.canEdit
  }

  func applyDurableEdit(
    _ command: SharedDraftCommand,
    commit: @MainActor () async throws -> DraftSnapshot
  ) async throws {
    guard command.accountID == draft.accountID, command.draftID == draft.id else {
      throw AccountError.accountChanged
    }
    try await commitMutation(
      SourceMutation(
        range: NSRange(location: command.edit.location, length: command.edit.length),
        expected: command.edit.expectedText, replacement: command.edit.replacement),
      expectedGeneration: command.expectedGeneration, commit: commit)
  }

  func commitMutation(
    _ mutation: SourceMutation, expectedGeneration: UInt64,
    commit: @MainActor () async throws -> DraftSnapshot
  ) async throws {
    guard canMutate else { throw SourceMutation.MutationError.compositionActive }
    guard session.generation == expectedGeneration else { throw DraftError.staleGeneration }
    let result = try mutation.applying(to: session.text)
    let changed = !result.utf8.elementsEqual(session.text.utf8)
    guard !changed || expectedGeneration < UInt64.max else { throw DraftError.staleGeneration }
    isApplyingDurableEdit = true
    let wasFirstResponder = session.textView.isFirstResponder
    session.textView.isEditable = false
    defer {
      isApplyingDurableEdit = false
      session.textView.isEditable = document.chrome.access.canEdit
      if wasFirstResponder { session.textView.becomeFirstResponder() }
    }
    guard await waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
    guard session.generation == expectedGeneration, !session.isComposing,
      !session.writingToolsActive
    else { throw DraftError.staleGeneration }
    let committed = try await commit()
    guard committed.id == draft.id, committed.accountID == draft.accountID,
      committed.generation == (changed ? expectedGeneration + 1 : expectedGeneration),
      committed.text.utf8.elementsEqual(result.utf8)
    else {
      saveState = .localFailure(
        message: String(
          localized:
            "The accepted edit couldn't be matched to this editor. Keep it open to recover both versions."
        ))
      throw NotebookEditError.invalidCommittedEdit
    }
    if changed {
      do {
        try session.apply(mutation, documentID: session.documentID, generation: expectedGeneration)
      } catch {
        saveState = .localFailure(
          message: String(
            localized:
              "The accepted edit is on this iPhone, but couldn't be applied to the editor. Keep it open to recover both versions."
          ))
        throw error
      }
    }
    draft = committed
    document.draft = committed
    document.chrome = notebook.chrome(gist: document.gist, draft: committed)
    saveState = NotebookModel.interfaceSaveState(committed.state)
    guard await waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
  }

  func retryLocalSave() {
    persist(text: session.text, generation: session.generation)
  }

  func didReconnect() {
    if saveState == .reconnectRequired { saveState = .savedLocally }
  }

  func publish(reason: PublishReason = .manual) async {
    guard canMutate, !isPublishing, !document.isRecovery, saveState.canPublish else { return }
    if reason != .manual, !autosaveAllowed { return }
    autosaveTask?.cancel()
    autosaveTask = nil
    isPublishing = true
    defer { isPublishing = false }
    if let persistence, !(await persistence.value) { return }
    guard canMutate, reason == .manual || autosaveAllowed else { return }
    let expectedGeneration = session.generation
    saveState = .savingToGitHub
    do {
      let saved = try await notebook.publish(
        draftID: draft.id, accountID: draft.accountID, reason: reason,
        expectedGeneration: reason == .manual ? nil : expectedGeneration,
        shouldPublish: { [weak self] in
          await MainActor.run {
            guard let self else { return false }
            return self.autosaveAllowed && self.session.generation == expectedGeneration
          }
        })
      draft = saved
      saveState =
        session.generation == saved.generation
        ? NotebookModel.interfaceSaveState(saved.state) : .unsaved
      if saved.state == .savedToGitHub || saved.state == .savedLocally {
        do {
          let gist = try await notebook.adoptPublication(saved)
          if let gist {
            document.gist = gist
            document.draft = saved
            document.chrome = notebook.chrome(gist: gist, draft: saved)
          }
          metadataError = nil
        } catch is CancellationError {
          do {
            draft = try await notebook.draftSnapshot(id: draft.id, accountID: draft.accountID)
            saveState = NotebookModel.interfaceSaveState(draft.state)
          } catch {
            logger.error("Cancelled save state couldn't be read: \(String(reflecting: type(of: error)), privacy: .public)")
            saveState = .localFailure(message: NotebookModel.message(for: error))
          }
        } catch {
          logger.error(
            "Saved-note metadata refresh failed: \(String(reflecting: type(of: error)), privacy: .public)"
          )
          metadataError = String(
            localized:
              "Your text was saved to GitHub, but its details couldn't be refreshed. Retry before sharing its link."
          )
        }
      }
    } catch {
      logger.error(
        "Publishing failed: \(String(reflecting: type(of: error)), privacy: .public)")
      do {
        let persisted = try await notebook.draftSnapshot(id: draft.id, accountID: draft.accountID)
        draft = persisted
        switch persisted.state {
        case .failed, .conflict, .reconnect, .offline, .savingToGitHub:
          saveState = NotebookModel.interfaceSaveState(persisted.state)
          return
        case .savedLocally, .savedToGitHub:
          break
        }
      } catch {
        logger.error(
          "Publication-state reload failed: \(String(reflecting: type(of: error)), privacy: .public)"
        )
        saveState = .localFailure(
          message: String(
            localized:
              "The save result couldn't be read from this iPhone. Keep the editor open and retry the local save."
          ))
        return
      }
      if error is AccountError {
        saveState = .reconnectRequired
      } else if let failure = error as? DraftError, failure == .readOnly {
        saveState = .publicationBlocked(
          message: String(localized: "This account no longer has permission to edit the gist."))
      } else if let failure = error as? GitHubClientError {
        switch failure {
        case .http(let status, _) where status == 401:
          saveState = .reconnectRequired
        case .incompleteGist, .fileTooLarge:
          saveState = .publicationBlocked(message: NotebookModel.message(for: failure))
        default:
          saveState = .cloudFailure(message: NotebookModel.message(for: failure))
        }
      } else {
        saveState = .cloudFailure(message: NotebookModel.message(for: error))
      }
    }
  }

  func waitForLocalSave() async -> Bool {
    if let persistence { return await persistence.value }
    return true
  }

  private func persist(text: String, generation: UInt64) {
    saveState = .unsaved
    let previous = persistence
    let draftID = draft.id
    let accountID = draft.accountID
    persistence = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      do {
        let saved = try await notebook.persist(
          draftID: draftID, accountID: accountID, text: text, generation: generation)
        draft = saved
        if session.generation == saved.generation {
          saveState =
            document.isRecovery
            ? .publicationBlocked(
              message: String(
                localized:
                  "The original note is unavailable. This local copy is preserved for recovery."))
            : NotebookModel.interfaceSaveState(saved.state)
        }
        return true
      } catch {
        logger.error(
          "Local persistence failed: \(String(reflecting: type(of: error)), privacy: .public)")
        if session.generation == generation {
          saveState = .localFailure(
            message: String(
              localized:
                "Your latest changes are still in the editor. Try saving on this iPhone again before closing it."
            ))
        }
        return false
      }
    }
  }
}
