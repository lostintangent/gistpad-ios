import Foundation
import Editor
import Interface
import Sync
import OSLog
import Observation

enum EditError: LocalizedError {
  case localPersistenceFailed

  var errorDescription: String? {
    String(
      localized:
        "Your latest changes couldn't be saved on this iPhone. Keep the editor open and retry the local save."
    )
  }
}

enum PublishReason: Equatable, Sendable {
  case manual
  case autosave
  case background
}

@MainActor
@Observable
final class FileSession {
  private(set) var file: File
  let editor: Editor
  private(set) var draft: Draft
  private var publishing: Task<Void, Never>?
  /// Why the last publish didn't land, until you type, publish again or reconnect GitHub.
  private var failure: PublishState?
  private(set) var isPerformingDestructiveAction = false
  private(set) var isApplyingDurableEdit = false
  private(set) var remoteInspectionProblem: RemoteReadProblem?
  var mode: FileMode = .preview
  @ObservationIgnored let library: Library
  @ObservationIgnored private var persistence: Task<Bool, Never>?
  @ObservationIgnored private var autosaveTask: Task<Void, Never>?
  @ObservationIgnored private var scheduledAutosave: AutosaveRequest?
  @ObservationIgnored private var lastEditingRequestID: UUID?
  @ObservationIgnored private let autosaveDelay: Duration
  @ObservationIgnored private var isInspectingRemote = false
  /// When this note last read GitHub, so opening it again reads only once that's stale.
  @ObservationIgnored private var refreshedAt: Date?
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "File")

  init(file: File, library: Library, autosaveDelay: Duration = .seconds(5)) {
    self.file = file
    draft = file.draft
    self.library = library
    self.autosaveDelay = autosaveDelay
    editor = Editor(
      fileID: file.id, text: draft.text, generation: draft.generation,
      showsFrontMatter: library.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
    if isNew { mode = .edit }
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

  /// A new gist, a new day or an empty file, which opens for writing.
  var isNew: Bool { draft.base == nil || draft.text.isEmpty }

  /// The gist's header and actions, always current with the library.
  var details: GistDetails { library.details(for: file) }

  /// Where this note stands with GitHub: read-only for a recovery copy, Saving while a publish
  /// runs, and otherwise the draft's state.
  var saveState: PublishState {
    if file.isRecovery { return .failed(.readOnly) }
    if isPublishing { return .savingToGitHub(generation: draft.generation) }
    if case .conflict = draft.state { return draft.state }
    return failure ?? draft.state
  }

  var isPublishing: Bool { publishing != nil }

  var canMutate: Bool {
    details.access.canEdit && editor.isSettled
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
    case .background:
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

  /// Brings the note's name and gist up to date after a change. A file GitHub renamed before you
  /// typed in it takes `filename`.
  func refreshMetadata(gist: Gist? = nil, filename: String? = nil) async throws {
    adopt(try await library.current(draft))
    if !draft.isSaved, let filename { adopt(draft.renamed(filename)) }
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

  /// Reads this note from GitHub as it opens or the app comes back. A note you haven't typed in
  /// takes GitHub's newer text, and one with edits shows the conflict.
  func inspectRemoteChanges() async {
    guard Library.isStale(refreshedAt), !isInspectingRemote, !isPublishing, canMutate,
      !file.isRecovery, draft.gistID != nil,
      library.account?.id == draft.accountID, library.pendingAccount == nil
    else { return }
    if case .conflict = draft.state { return }
    isInspectingRemote = true
    defer { isInspectingRemote = false }
    guard await waitForLocalSave() else { return }
    let generation = editor.generation
    do {
      guard
        case .remoteRead(let current, let remote?) = try await library.perform(
          .fetchRemote(draft)),
        current.id == draft.id, current.generation == generation,
        editor.generation == generation, !isPublishing, canMutate
      else { return }
      if !current.isSaved {
        if let content = remote.content, !sourceEqual(content, current.base) {
          // Every text change bumps the generation, so this is refused if you typed after the fetch.
          try await commitMutation(
            Edit(
              range: NSRange(location: 0, length: editor.text.utf16.count),
              expected: editor.text, replacement: content),
            expectedGeneration: current.generation
          ) { current.adopting(content, revision: remote.gist.revision) }
        }
      } else if case .review(let recorded) = try await library.perform(
        .recordRemote(current, remote: remote.content, revision: remote.gist.revision))
      {
        adopt(recorded)
      }
      remoteInspectionProblem = nil
      refreshedAt = .now
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
    draft.hasUnpublishedEdits || editor.generation > draft.generation
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
    editor.textView.isEditable = details.access.canEdit
  }

  func applyDurableEdit(
    _ edit: DraftEdit,
    commit: @MainActor () async throws -> Draft
  ) async throws {
    guard edit.draft.accountID == draft.accountID, edit.draft.id == draft.id else {
      throw AccountError.accountChanged
    }
    try await commitMutation(
      Edit(
        range: NSRange(location: editor.text.utf16.count, length: 0), expected: "",
        replacement: edit.text),
      expectedGeneration: edit.draft.generation, commit: commit)
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
    if changed {
      try editor.apply(edit, generation: expectedGeneration)
    }
    adopt(committed)
    guard await waitForLocalSave() else { throw EditError.localPersistenceFailed }
  }

  func didReconnect() {
    failure = nil
  }

  /// Points the file at the gist its publish just cached, so a new note's first publish gives it one.
  private func adoptPublishedGist() {
    guard draft.state == .savedToGitHub || draft.state == .savedLocally,
      let gist = library.cachedLibrary?.gists.first(where: { $0.id == draft.gistID })
    else { return }
    file.gist = gist
  }

  /// Takes the store's latest word on this draft. A read or publish that started before a keystroke
  /// can finish after that keystroke saves, and its older draft would make the edit look published.
  private func adopt(_ stored: Draft) {
    if stored.generation >= draft.generation { draft = stored }
    file.draft = draft
  }

  func waitForPublication() async {
    await publishing?.value
  }

  /// Leaving a note publishes your edits.
  func leave() async {
    editor.commitComposition()
    guard await waitForLocalSave(), hasUnpublishedChanges else { return }
    await publish(reason: .background)
  }

  func publish(
    reason: PublishReason = .manual,
    shouldContinue: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async {
    guard !Task.isCancelled, shouldContinue() else { return }
    if reason == .background { await waitForPublication() }
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
    failure = nil
    do {
      // A new gist publishes when you ask, even before you type in it.
      if reason == .manual, !draft.isSaved, draft.gistID == nil {
        draft = try await library.keep(draft)
      }
      adopt(try await library.publish(draft))
      adoptPublishedGist()
    } catch {
      if !(error is CancellationError || (error as? URLError)?.code == .cancelled) {
        logger.error(
          "Publishing failed: \(String(reflecting: type(of: error)), privacy: .public)")
        failure = PublishState(failure: error)
      }
      // The publish may have recorded sent text or found its gist before it stopped.
      if let current = try? await library.current(draft) { adopt(current) }
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
    persistence = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      do {
        draft = try await library.save(draft, text: text, generation: generation)
        failure = nil
        return true
      } catch {
        logger.error(
          "Local persistence failed: \(String(reflecting: type(of: error)), privacy: .public)")
        return false
      }
    }
  }
}
