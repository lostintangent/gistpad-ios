import Foundation
import Editor
import Interface
import Sync
import OSLog
import Observation

enum EditError: LocalizedError {
  case localPersistenceFailed
  case invalidCommittedEdit

  var errorDescription: String? {
    switch self {
    case .localPersistenceFailed:
      String(
        localized:
          "Your latest changes couldn't be saved on this iPhone. Keep the editor open and retry the local save."
      )
    case .invalidCommittedEdit:
      String(
        localized:
          "The accepted edit couldn't be matched to this editor. Keep it open to recover both versions."
      )
    }
  }
}

@MainActor
@Observable
final class FileSession {
  private(set) var file: File
  let editor: Editor
  private(set) var draft: Draft
  private var publishing: Task<Void, Never>?
  /// Reconnecting GitHub lets a note that's waiting on it publish again.
  private var hasReconnected = false
  private(set) var isPerformingDestructiveAction = false
  private(set) var isApplyingDurableEdit = false
  private(set) var remoteInspectionProblem: RemoteReadProblem?
  var mode: FileMode = .preview
  @ObservationIgnored let library: Library
  @ObservationIgnored private var persistence: Task<Bool, Never>?
  @ObservationIgnored private var autosaveTask: Task<Void, Never>?
  @ObservationIgnored private var scheduledAutosave: AutosaveRequest?
  @ObservationIgnored private var lastEditingRequestID: UUID?
  @ObservationIgnored private var isDiscarded = false
  @ObservationIgnored private let autosaveDelay: Duration
  @ObservationIgnored private var isInspectingRemote = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "File")

  init(
    file: File, draft: Draft, library: Library,
    autosaveDelay: Duration = .seconds(5)
  ) {
    self.file = file
    self.draft = draft
    self.library = library
    self.autosaveDelay = autosaveDelay
    editor = Editor(
      fileID: file.id, text: draft.text, generation: draft.generation,
      showsFrontMatter: library.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
    if draft.baseContent == nil { mode = .edit }
    editor.textView.isEditable = details.access.canEdit
    applyWritingPreferences()
    editor.onEdit = { [weak self] text, generation in
      self?.persist(text: text, generation: generation)
    }
    PlatformBridge.register(self, library: library)
    observeAutosave()
  }

  /// Adds images at the caret, uploading them to the library's account.
  @ObservationIgnored private(set) lazy var images = ImageUpload(session: self) {
    [library = self.library, accountID = self.draft.accountID] image, gistID in
    try await library.uploadImage(image, gistID: gistID, accountID: accountID)
  }

  /// The gist's header and actions, always current with the library.
  var details: GistDetails { library.details(for: file) }

  /// Where this note stands with GitHub: read-only for a recovery copy, Saving while a publish
  /// runs, and otherwise the draft's state.
  var saveState: PublishState {
    if file.isRecovery { return .failed(.readOnly) }
    if isPublishing { return .savingToGitHub(generation: draft.generation) }
    if draft.state == .reconnect, hasReconnected { return .savedLocally }
    return draft.state
  }

  var isPublishing: Bool { publishing != nil }

  var canMutate: Bool {
    details.access.canEdit && !isDiscarded && editor.isSettled
      && !isPerformingDestructiveAction
      && !isApplyingDurableEdit
  }

  var remoteInspectionStatus: GitHubStatusState {
    guard let problem = remoteInspectionProblem else { return .idle }
    switch saveState {
    case .failed, .conflict, .reconnect:
      return .idle
    default:
      return problem.status(
        heading: String(localized: "Couldn't check for updates"), detail: nil)
    }
  }

  func requestCreationFocus() {
    guard let request = file.editingRequestID, request != lastEditingRequestID, canMutate
    else { return }
    lastEditingRequestID = request
    mode = .edit
    editor.requestFocusAtEnd()
  }

  struct AutosaveRequest: Equatable {
    let generation: UInt64
    let eligible: Bool
  }

  var autosaveRequest: AutosaveRequest {
    AutosaveRequest(
      generation: editor.generation,
      eligible: autosaveAllowed && saveState == .savedLocally && hasUnpublishedChanges)
  }

  private var autosaveAllowed: Bool {
    library.isForeground && library.account?.id == draft.accountID && library.pendingAccount == nil
      && library.state.loadState == .ready
      && library.account?.preferences.isAutoSaveEnabled == true
      && canMutate && editor.textView.markedTextRange == nil && !file.isRecovery
  }

  private func publicationAllowed(reason: PublishReason) -> Bool {
    switch reason {
    case .manual: true
    case .autosave: autosaveAllowed
    case .background, .leaving:
      library.account?.id == draft.accountID && library.pendingAccount == nil
        && editor.isSettled && editor.textView.markedTextRange == nil
    }
  }

  /// Schedules autosave now and again whenever its request changes, such as with each keystroke.
  private func observeAutosave() {
    withObservationTracking {
      _ = updateAutosave()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeAutosave() }
    }
  }

  @discardableResult
  func updateAutosave() -> Task<Void, Never>? {
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
    let current = try await library.draft(id: draft.id, accountID: draft.accountID)
    if current.generation >= draft.generation { draft = current }
    file.draft = draft
    file.filename = draft.filename
    if let gist { file.gist = gist }
    editor.textView.isEditable =
      details.access.canEdit && !isPerformingDestructiveAction && !isApplyingDurableEdit
    applyWritingPreferences()
  }

  private func applyWritingPreferences() {
    let enabled = library.account?.preferences.booleanValue(.isSpellcheckEnabled) ?? true
    editor.textView.spellCheckingType = enabled ? .yes : .no
    editor.setShowsFrontMatter(
      library.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
  }

  func markRecovery() {
    file.isRecovery = true
    file.libraryRowID = draft.id.uuidString
  }

  func inspectRemoteChanges() async {
    guard !isInspectingRemote, !isPublishing, canMutate, !file.isRecovery,
      draft.gistID != nil, !draft.isDiscardableBlank,
      library.account?.id == draft.accountID, library.pendingAccount == nil
    else { return }
    if case .conflict = draft.state { return }
    isInspectingRemote = true
    defer { isInspectingRemote = false }
    guard await waitForLocalSave() else { return }
    let generation = editor.generation
    do {
      guard
        case .remoteRead(let current, let remote) = try await library.perform(
          .fetchRemote(draftID: draft.id)),
        current.id == draft.id, current.generation == generation,
        editor.generation == generation, !isPublishing, canMutate
      else { return }
      if let remote, let content = remote.content, current.adoptsRemote(content) {
        // Every text change bumps the generation, so this commit is refused if any edit or publish
        // landed after the fetch. Adoption can't overwrite unpublished text.
        try await commitMutation(
          Edit(
            range: NSRange(location: 0, length: editor.text.utf16.count),
            expected: editor.text, replacement: content),
          expectedGeneration: current.generation
        ) {
          guard
            case .review(let adopted) = try await library.perform(
              .adoptRemote(
                draftID: draft.id, generation: current.generation, remote: content,
                revision: remote.gist.revision))
          else { throw ChangeError.staleReview }
          return adopted
        }
      } else if case .review(let recorded) = try await library.perform(
        .recordRemote(
          draftID: draft.id, generation: current.generation, remote: remote?.content,
          revision: remote?.gist.revision))
      {
        draft = recorded
        file.draft = recorded
      }
      remoteInspectionProblem = nil
    } catch {
      logger.error(
        "Remote inspection failed: \(String(reflecting: type(of: error)), privacy: .public)")
      remoteInspectionProblem =
        RemoteRead.needsReconnect(error) ? RemoteRead.problem(for: error) : nil
    }
  }

  func adoptPresentation(_ incoming: File) {
    guard incoming.accountID == draft.accountID,
      incoming.gist?.id == file.gist?.id, incoming.filename == draft.filename
    else { return }
    file.libraryRowID = incoming.libraryRowID
    file.editingRequestID = incoming.editingRequestID
    file.revealsDetail = incoming.revealsDetail
    if let gist = incoming.gist { file.gist = gist }
  }

  var hasUnpublishedChanges: Bool {
    guard !isDiscarded else { return false }
    if draft.isDiscardableBlank, editor.text.utf8.elementsEqual(draft.text.utf8) { return false }
    guard let base = draft.baseContent else { return true }
    return !editor.text.utf8.elementsEqual(base.utf8) || draft.attemptedGeneration != nil
  }

  func reviewContext() throws -> Conflict {
    let review = try Conflict(draft: draft)
    guard editor.generation == draft.generation,
      editor.text.utf8.elementsEqual(draft.text.utf8)
    else { throw ChangeError.staleReview }
    return review
  }

  func applyReview(_ review: Conflict, text: String, publishes: Bool) async throws {
    guard review.matches(draft), editor.generation == review.draft.generation else {
      throw ChangeError.staleReview
    }
    let changed = !text.utf8.elementsEqual(editor.text.utf8)
    let generation = editor.generation + (changed ? 1 : 0)
    try await commitMutation(
      Edit(
        range: NSRange(location: 0, length: editor.text.utf16.count),
        expected: editor.text, replacement: text),
      expectedGeneration: review.draft.generation
    ) {
      guard
        case .review(let resolved) = try await library.perform(
          .resolveConflict(review, text: text, generation: generation))
      else {
        throw ChangeError.staleReview
      }
      return resolved
    }
    if publishes { await publish() }
  }

  func beginDestructiveAction() throws {
    guard canMutate, !isPublishing else { throw ChangeError.publicationInProgress }
    isPerformingDestructiveAction = true
    editor.textView.isEditable = false
  }

  func endDestructiveAction() {
    isPerformingDestructiveAction = false
    editor.textView.isEditable = details.access.canEdit && !isDiscarded
  }

  func applyDurableEdit(
    _ edit: DraftEdit,
    commit: @MainActor () async throws -> Draft
  ) async throws {
    guard edit.accountID == draft.accountID, edit.draftID == draft.id else {
      throw AccountError.accountChanged
    }
    try await commitMutation(
      Edit(
        range: NSRange(location: editor.text.utf16.count, length: 0), expected: "",
        replacement: edit.text),
      expectedGeneration: edit.expectedGeneration, commit: commit)
  }

  func commitMutation(
    _ edit: Edit, expectedGeneration: UInt64,
    commit: @MainActor () async throws -> Draft
  ) async throws {
    guard canMutate else { throw Edit.MutationError.compositionActive }
    guard editor.generation == expectedGeneration else { throw DraftError.staleGeneration }
    let result = try edit.applying(to: editor.text)
    let changed = !result.utf8.elementsEqual(editor.text.utf8)
    isApplyingDurableEdit = true
    let wasFirstResponder = editor.textView.isFirstResponder
    editor.textView.isEditable = false
    defer {
      isApplyingDurableEdit = false
      editor.textView.isEditable = details.access.canEdit
      if wasFirstResponder { editor.textView.becomeFirstResponder() }
    }
    guard await waitForLocalSave() else { throw EditError.localPersistenceFailed }
    guard editor.generation == expectedGeneration, editor.isSettled
    else { throw DraftError.staleGeneration }
    let committed = try await commit()
    guard committed.id == draft.id, committed.accountID == draft.accountID,
      committed.generation == (changed ? expectedGeneration + 1 : expectedGeneration),
      committed.text.utf8.elementsEqual(result.utf8)
    else {
      throw EditError.invalidCommittedEdit
    }
    if changed {
      try editor.apply(edit, generation: expectedGeneration)
    }
    draft = committed
    file.draft = committed
    guard await waitForLocalSave() else { throw EditError.localPersistenceFailed }
  }

  func didReconnect() {
    hasReconnected = true
  }

  // Library retries can save this file while it is open, so its persisted state is re-read.
  func refreshPersistedState() async {
    guard !isPublishing, !isDiscarded, !file.isRecovery else { return }
    let persisted: Draft
    do {
      persisted = try await library.draft(id: draft.id, accountID: draft.accountID)
    } catch {
      logger.error(
        "File state refresh failed: \(String(reflecting: type(of: error)), privacy: .public)")
      return
    }
    draft = persisted
    file.draft = persisted
    hasReconnected = false
    adoptPublishedGist()
  }

  /// Points the file at the gist its publish just cached, so a new note's first publish gives it one.
  private func adoptPublishedGist() {
    guard draft.state == .savedToGitHub || draft.state == .savedLocally,
      let gist = library.cachedLibrary?.gists.first(where: { $0.id == draft.gistID })
    else { return }
    file.gist = gist
  }

  func waitForPublication() async {
    await publishing?.value
  }

  @discardableResult
  func leave() async -> Bool {
    editor.commitComposition()
    guard await waitForLocalSave() else { return false }
    if draft.isDiscardableBlank, library.isDraftSelected(draft.id) { return false }
    if draft.isDiscardableBlank,
      canMutate, !isPublishing,
      editor.generation == draft.generation, editor.text.utf8.elementsEqual(draft.text.utf8)
    {
      do {
        try beginDestructiveAction()
        defer { endDestructiveAction() }
        if try await library.discardBlankDraft(draft) {
          isDiscarded = true
          autosaveTask?.cancel()
          autosaveTask = nil
          return true
        }
      } catch {
        logger.error(
          "Blank draft cleanup failed: \(String(reflecting: type(of: error)), privacy: .public)")
        return false
      }
    }
    guard hasUnpublishedChanges else { return false }
    await publish(reason: .leaving)
    return false
  }

  func publish(
    reason: PublishReason = .manual,
    shouldContinue: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async {
    guard !Task.isCancelled, shouldContinue() else { return }
    if reason == .background || reason == .leaving { await waitForPublication() }
    guard !Task.isCancelled, shouldContinue(), publicationAllowed(reason: reason) else { return }
    if reason != .manual, !hasUnpublishedChanges { return }
    guard canMutate, saveState.canPublish else { return }
    autosaveTask?.cancel()
    autosaveTask = nil
    let task = Task {
      await send(reason: reason, shouldContinue: shouldContinue)
      publishing = nil
    }
    publishing = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  private func send(
    reason: PublishReason, shouldContinue: @escaping @MainActor @Sendable () -> Bool
  ) async {
    guard await waitForLocalSave(), !Task.isCancelled, shouldContinue(), canMutate,
      publicationAllowed(reason: reason)
    else { return }
    let expectedGeneration = editor.generation
    hasReconnected = false
    do {
      let saved = try await library.publish(
        draftID: draft.id, accountID: draft.accountID, reason: reason,
        expectedGeneration: reason == .manual ? nil : expectedGeneration,
        shouldPublish: { [weak self] in
          await MainActor.run {
            guard let self else { return false }
            return shouldContinue() && self.canMutate && !self.file.isRecovery
              && self.publicationAllowed(reason: reason)
              && self.editor.generation == expectedGeneration
          }
        })
      // Typing saved after GitHub acknowledged the publish is newer than what it returns.
      if saved.generation >= draft.generation { draft = saved }
      file.draft = draft
      adoptPublishedGist()
    } catch {
      if !(error is CancellationError) {
        logger.error(
          "Publishing failed: \(String(reflecting: type(of: error)), privacy: .public)")
      }
      do {
        draft = try await library.draft(id: draft.id, accountID: draft.accountID)
      } catch {
        logger.error(
          "Publication-state reload failed: \(String(reflecting: type(of: error)), privacy: .public)"
        )
      }
    }
  }

  func waitForLocalSave() async -> Bool {
    await persistence?.value ?? true
  }

  /// Leaving the app saves every open file on this iPhone first, then publishes them one by one
  /// for as long as the system lets the app keep running.
  static func publishOnBackground(
    _ sessions: [FileSession],
    shouldContinue: @escaping @MainActor @Sendable () -> Bool
  ) async {
    for session in sessions { _ = await session.waitForLocalSave() }
    for session in sessions {
      guard !Task.isCancelled, shouldContinue() else { return }
      await session.publish(reason: .background, shouldContinue: shouldContinue)
    }
  }

  private func persist(text: String, generation: UInt64) {
    let previous = persistence
    let draftID = draft.id
    let accountID = draft.accountID
    persistence = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      do {
        draft = try await library.persist(
          draftID: draftID, accountID: accountID, text: text, generation: generation)
        return true
      } catch {
        logger.error(
          "Local persistence failed: \(String(reflecting: type(of: error)), privacy: .public)")
        return false
      }
    }
  }
}
