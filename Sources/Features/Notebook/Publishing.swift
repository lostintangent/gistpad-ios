import Foundation
import Observation
import Sync

// Edits publish five seconds after you stop typing, and whenever you leave a note or the app.
// A draft lives only until GitHub has its text.

public enum PublishReason: Equatable, Sendable {
  case manual
  case autosave
  case background
}

extension Library {
  /// Points the open file at the gist it published to, keeping it selected under its new row.
  private func apply(published saved: Draft, gist: Gist) {
    guard
      loadedFile?.draft.id == saved.id
        || (loadedFile?.gist?.id == gist.id && loadedFile?.filename == saved.filename)
    else { return }
    let wasSelected = state.selectedID == loadedFile?.rowID
    loadedFile?.gist = gist
    loadedFile?.draft = saved
    if loadedFile?.libraryRowID == saved.id.uuidString { loadedFile?.libraryRowID = nil }
    if wasSelected, opening == nil {
      state.selectedID = loadedFile?.rowID
      remember(FileReference(gistID: gist.id, filename: saved.filename, draftID: saved.id))
    }
  }

  /// Publishes each file with unpublished edits, in order, through its editor when it's open. The
  /// first offline result stops the sweep, and the next launch or return to the app retries it.
  public func publishDrafts() async {
    guard let accountID = account?.id, pendingAccount == nil else { return }
    for draft in localDrafts where draft.hasUnpublishedEdits {
      guard !Task.isCancelled else { break }
      if let session = sessions[draft.id] {
        await session.publish(reason: .background)
        if session.saveState == .failed(.network) { break }
      } else {
        do { _ = try await publish(draft) } catch is URLError { break } catch {}
      }
    }
    try? await reloadLocalState(accountID: accountID)
  }

  public func publish(_ draft: Draft) async throws -> Draft {
    let accountID = draft.accountID
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    let saved = try await sync.publish(draft)
    if account?.id == accountID {
      libraryRequest = UUID()
      isRefreshingRemote = false
      if state.loadState == .loading { state.loadState = .ready }
      try await reloadLocalState(accountID: accountID)
      if let gist = cachedLibrary?.gists.first(where: { $0.id == saved.gistID }) {
        apply(published: saved, gist: gist)
      }
    }
    return saved
  }
}

extension FileSession {
  var isPublishing: Bool { publishing != nil }

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
      && canMutate && !file.isRecovery
  }

  private func publicationAllowed(reason: PublishReason) -> Bool {
    switch reason {
    case .manual: true
    case .autosave: autosaveAllowed
    case .background:
      library.account?.id == draft.accountID && library.pendingAccount == nil
        && editor.isSettled
    }
  }

  /// Schedules autosave now and again whenever its request changes, such as with each keystroke.
  func observeAutosave() {
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

  var hasUnpublishedChanges: Bool {
    draft.hasUnpublishedEdits || editor.generation > draft.generation
  }

  public func didReconnect() {
    failure = nil
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

  /// Leaving a note publishes your edits.
  public func leave() async {
    editor.commitComposition()
    guard await waitForLocalSave() else { return }
    if !draft.isSaved, draft.gistID == nil { return library.close(self) }
    guard hasUnpublishedChanges else { return }
    await publish(reason: .background)
  }

  public func publish(
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

  /// Leaving the app saves every open file on this iPhone first, then publishes them one by one
  /// for as long as the system lets the app keep running.
  public static func publishOnBackground(
    _ sessions: [FileSession],
    shouldContinue: @escaping @MainActor @Sendable () -> Bool
  ) async {
    for session in sessions { _ = await session.waitForLocalSave() }
    for session in sessions {
      guard !Task.isCancelled, shouldContinue() else { return }
      await session.publish(reason: .background, shouldContinue: shouldContinue)
    }
  }
}
