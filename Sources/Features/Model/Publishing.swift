import Foundation
import Observation
import Store

// Edits publish five seconds after you stop typing, and whenever you leave a note or the app.
// A draft lives only until GitHub has its text.

public enum PublishReason: Equatable, Sendable {
  case manual
  case autosave
  case background
}

extension GistPadModel {
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
      if let fileEditor = editors[draft.id] {
        await fileEditor.publish(reason: .background)
        if fileEditor.saveState == .failed(.network) { break }
      } else {
        do { _ = try await publish(draft) } catch is URLError { break } catch {}
      }
    }
    try? await reloadLocalState(accountID: accountID)
  }

  public func publish(_ draft: Draft) async throws -> Draft {
    let accountID = draft.accountID
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    let github = await client(accountID: accountID)
    let saved = try await serially { try await publish(draft, to: github) }
    if account?.id == accountID {
      libraryRequest = UUID()
      isRefreshingRemote = false
      if state.loadState == .loading { state.loadState = .ready }
      try await reloadLocalState(accountID: accountID)
      if let gist = gistCache?.gists.first(where: { $0.id == saved.gistID }) {
        apply(published: saved, gist: gist)
      }
    }
    return saved
  }

  /// Publishes your draft as this iPhone stores it now: if GitHub has its base, its sent text or
  /// already its text, your text is sent, and anything else on GitHub is a conflict. A note you
  /// haven't typed in has nothing to publish, and typing during the publish hands over to the
  /// publish that typing schedules.
  private func publish(_ draft: Draft, to github: GitHubClient) async throws -> Draft {
    try Task.checkCancellation()
    var draft = try await draftStore.current(draft)
    guard draft.isSaved else { return draft }
    if case .conflict = draft.state { return draft }
    // Sent text stays on the draft if this is cut off, so the next publish checks GitHub for it first.
    if draft.gistID == nil, let sent = draft.sent {
      draft = try await findCreatedGist(sent, for: draft, on: github)
    }
    if draft.isSaved, draft.gistID == nil, draft.description == DailyNote.gistDescription {
      draft = try await joinDailyGist(draft, on: github)
    }
    if draft.isSaved, let gistID = draft.gistID {
      draft = try await compareWithGitHub(draft, gistID: gistID, on: github)
    }
    // Newer text from the web reaches a note when it's opened, not by publishing.
    guard draft.isSaved else { return draft }
    if case .conflict = draft.state { return draft }
    return try await send(draft, to: github)
  }

  /// Records your text as sent, then sends it. When GitHub confirms it, it becomes the base.
  private func send(_ draft: Draft, to github: GitHubClient) async throws -> Draft {
    try await draftStore.recordSent(
      id: draft.id, accountID: draft.accountID, content: draft.text, generation: draft.generation)
    let gist: Gist
    if let gistID = draft.gistID {
      gist = try await github.updateGist(id: gistID, files: [draft.filename: .content(draft.text)])
    } else {
      gist = try await github.createGist(
        description: draft.description, filename: draft.filename,
        content: Gist.File.encodeContent(draft.text))
    }
    let confirmed = try await github.content(gist: gist, filename: draft.filename)
    guard sourceEqual(confirmed, draft.text) else { throw DraftError.notConfirmed }
    try updateCache(draft.accountID) {
      $0.insert(gist)
      $0.store(confirmed, of: draft.filename, in: gist)
    }
    return try await draftStore.confirm(
      id: draft.id, accountID: draft.accountID, gistID: draft.gistID ?? gist.id, content: confirmed,
      revision: gist.revision)
  }

  /// Reads GitHub's copy of the file. Sent text GitHub doesn't have is forgotten, and the store
  /// confirms the sent text or your text if GitHub has either, or raises a conflict unless GitHub
  /// still has the base.
  private func compareWithGitHub(
    _ draft: Draft, gistID: String, on github: GitHubClient
  ) async throws -> Draft {
    let remote = try await github.remoteFile(
      gistID: gistID, ownerID: draft.githubUserID, filename: draft.filename)
    try cache(remote, filename: draft.filename, accountID: draft.accountID)
    var draft = draft
    if let sent = draft.sent, !sourceEqual(remote.content, sent) {
      draft = try await draftStore.forgetSent(id: draft.id, accountID: draft.accountID)
    }
    return try await draftStore.compareWithGitHub(
      draft, remote: remote.content, revision: remote.gist.revision)
  }

  /// A create that was cut off may have made the gist already. It's found by its description and
  /// a same-named file with the sent bytes, so a gist is never created twice, and sent is
  /// confirmed. Otherwise sent is forgotten.
  private func findCreatedGist(
    _ sent: String, for draft: Draft, on github: GitHubClient
  ) async throws -> Draft {
    let size = Gist.File.encodeContent(sent).utf8.count
    for gist in try await github.listGists()
    where (gist.description ?? "") == draft.description && gist.files[draft.filename]?.size == size {
      let remote = try await github.remoteFile(
        gistID: gist.id, ownerID: draft.githubUserID, filename: draft.filename)
      if sourceEqual(remote.content, sent) {
        try updateCache(draft.accountID) {
          $0.insert(remote.gist)
          $0.store(sent, of: draft.filename, in: remote.gist)
        }
        return try await draftStore.confirm(
          id: draft.id, accountID: draft.accountID, gistID: remote.gist.id, content: sent,
          revision: remote.gist.revision)
      }
    }
    return try await draftStore.forgetSent(id: draft.id, accountID: draft.accountID)
  }

  /// A new day joins the Daily notes gist GitHub has, which the web may have started since this
  /// iPhone last saw the list, and creates one only when there's none. The gist joins the cached
  /// list, so the day finds it before the next refresh even if this publish doesn't land.
  private func joinDailyGist(_ draft: Draft, on github: GitHubClient) async throws -> Draft {
    guard let daily = try await github.listGists().first(where: \.isDailyNote) else { return draft }
    try updateCache(draft.accountID) { $0.insert(daily) }
    return try await draftStore.join(gistID: daily.id, id: draft.id, accountID: draft.accountID)
  }
}

extension PublishState {
  /// What you see after a publish fails.
  init(failure error: any Error) {
    self =
      switch error {
      case GitHubClientError.http(status: 401), is AccountError: .reconnect
      case GitHubClientError.http(let status): .failed(.http(status: status))
      case GitHubClientError.incompleteGist, GitHubClientError.fileTooLarge: .failed(.incompleteRemote)
      case DraftError.readOnly: .failed(.readOnly)
      default: .failed(.network)
      }
  }
}

extension GistFileEditor {
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
    model.isForeground && model.account?.id == draft.accountID && model.pendingAccount == nil
      && model.state.loadState == .ready
      && model.account?.preferences.isAutoSaveEnabled == true
      && canMutate && !file.isRecovery
  }

  private func publicationAllowed(reason: PublishReason) -> Bool {
    switch reason {
    case .manual: true
    case .autosave: autosaveAllowed
    case .background:
      model.account?.id == draft.accountID && model.pendingAccount == nil
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
      let gist = model.gistCache?.gists.first(where: { $0.id == draft.gistID })
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
    if !draft.isSaved, draft.gistID == nil { return model.close(self) }
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
        draft = try await model.keep(draft)
      }
      adopt(try await model.publish(draft))
      adoptPublishedGist()
    } catch {
      if !(error is CancellationError || (error as? URLError)?.code == .cancelled) {
        logger.error(
          "Publishing failed: \(String(reflecting: type(of: error)), privacy: .public)")
        failure = PublishState(failure: error)
      }
      // The publish may have recorded sent text or found its gist before it stopped.
      if let current = try? await model.current(draft) { adopt(current) }
    }
  }

  /// Leaving the app saves every open file on this iPhone first, then publishes them one by one
  /// for as long as the system lets the app keep running.
  public static func publishOnBackground(
    _ editors: [GistFileEditor],
    shouldContinue: @escaping @MainActor @Sendable () -> Bool
  ) async {
    for fileEditor in editors { _ = await fileEditor.waitForLocalSave() }
    for fileEditor in editors {
      guard !Task.isCancelled, shouldContinue() else { return }
      await fileEditor.publish(reason: .background, shouldContinue: shouldContinue)
    }
  }
}
