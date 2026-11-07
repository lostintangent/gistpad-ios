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
  private func apply(published saved: GistFileDraft, gist: Gist) {
    guard
      loadedFile?.draftID == saved.id
        || (loadedFile?.gist?.id == gist.id && loadedFile?.filename == saved.filename)
    else { return }
    let wasSelected = state.selectedID == loadedFile?.rowID
    loadedFile?.gist = gist
    loadedFile?.update(saved)
    if loadedFile?.libraryRowID == saved.id.uuidString { loadedFile?.libraryRowID = nil }
    if wasSelected, opening == nil {
      state.selectedID = loadedFile?.rowID
      remember(.gist(id: gist.id, filename: saved.filename))
    }
  }

  /// Publishes each file with unpublished edits, in order, through its editor when it's open. The
  /// first offline result stops the sweep, and the next launch or return to the app retries it.
  public func publishDrafts() async {
    guard let accountID = account?.id, pendingAccount == nil else { return }
    for draft in drafts {
      guard !Task.isCancelled else { break }
      if let fileEditor = editors[draft.id] {
        await fileEditor.publish(reason: .background)
        if fileEditor.status == .failed(.network) { break }
      } else {
        do { _ = try await publish(draft) } catch is URLError { break } catch {}
      }
    }
    try? await reloadLocalState(accountID: accountID)
  }

  /// Publishes the file's stored draft, and returns it as the store has it after: kept, or let go
  /// once GitHub has its text. A file you haven't typed in has nothing to publish.
  public func publish(_ draft: GistFileDraft) async throws -> GistFileDraft? {
    let accountID = draft.accountID
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    let github = await client(accountID: accountID)
    let saved = try await serially { try await publish(draft, to: github) }
    if draft.gistID == nil, let gistID = saved?.gistID { publishedGistIDs[draft.id] = gistID }
    if account?.id == accountID {
      libraryRequest = UUID()
      isRefreshingRemote = false
      if state.loadState == .loading { state.loadState = .ready }
      try await reloadLocalState(accountID: accountID)
      if let saved, let gist = gistCache?.gists.first(where: { $0.id == saved.gistID }) {
        apply(published: saved, gist: gist)
      }
    }
    return saved
  }

  /// Publishes your draft as this iPhone stores it now: if GitHub has its base, its sent text or
  /// already its text, your text is sent, and anything else on GitHub is a conflict. A note you
  /// haven't typed in has nothing to publish, and typing during the publish hands over to the
  /// publish that typing schedules.
  private func publish(_ read: GistFileDraft, to github: GitHubClient) async throws -> GistFileDraft? {
    try Task.checkCancellation()
    guard var draft = try await draftStore.current(read) else { return nil }
    guard draft.conflict == nil else { return draft }
    // Sent text stays on the draft if this is cut off, so the next publish checks GitHub for it first.
    if draft.gistID == nil, let sent = draft.sent {
      draft = try await findCreatedGist(sent, for: draft, on: github)
    }
    if draft.gistID == nil, draft.newGistName == DailyNote.gistDescription {
      draft = try await joinDailyGist(draft, on: github)
    }
    if !draft.isPublished, let gistID = draft.gistID {
      draft = try await compareWithGitHub(draft, gistID: gistID, on: github)
    }
    // Newer text from the web reaches a note when it's opened, not by publishing.
    guard !draft.isPublished, draft.conflict == nil else { return draft }
    return try await send(draft, to: github)
  }

  /// Records your text as sent, then sends it. When GitHub confirms it, it becomes the base.
  private func send(_ draft: GistFileDraft, to github: GitHubClient) async throws -> GistFileDraft {
    try await draftStore.recordSent(draft)
    let gist: Gist
    if let gistID = draft.gistID {
      gist = try await github.updateGist(id: gistID, files: [draft.filename: .content(draft.text)])
    } else {
      gist = try await github.createGist(
        description: draft.newGistName ?? "", filename: draft.filename,
        content: Gist.File.encodeContent(draft.text))
    }
    let confirmed = try await github.content(gist: gist, filename: draft.filename)
    guard sourceEqual(confirmed, draft.text) else { throw DraftError.notConfirmed }
    try updateCache(draft.accountID) {
      $0.insert(gist)
      $0.store(confirmed, of: draft.filename, in: gist)
    }
    return try await draftStore.confirm(
      draft, gistID: draft.gistID ?? gist.id,
      base: GitHubVersion(text: confirmed, revision: gist.revision))
  }

  /// Your GitHub user, who owns the gists you can publish to.
  private var ownerID: Int64 {
    get throws {
      guard let id = account?.githubUserID else { throw AccountError.reconnectGitHub }
      return id
    }
  }

  /// Reads GitHub's copy of the file. Sent text GitHub doesn't have is forgotten, and the store
  /// confirms the sent text or your text if GitHub has either, or raises a conflict unless GitHub
  /// still has the base.
  private func compareWithGitHub(
    _ draft: GistFileDraft, gistID: String, on github: GitHubClient
  ) async throws -> GistFileDraft {
    let remote = try await github.remoteFile(
      gistID: gistID, ownerID: try ownerID, filename: draft.filename)
    try cache(remote, filename: draft.filename, accountID: draft.accountID)
    var draft = draft
    if let sent = draft.sent, !sourceEqual(remote.content, sent) {
      draft = try await draftStore.forgetSent(draft)
      if draft.isPublished { return draft }
    }
    return try await draftStore.compareWithGitHub(
      draft, remote: remote.content, revision: remote.gist.revision)
  }

  /// A create that was cut off may have made the gist already. It's found by its description and
  /// a same-named file with the sent bytes, so a gist is never created twice, and sent is
  /// confirmed. Otherwise sent is forgotten.
  private func findCreatedGist(
    _ sent: String, for draft: GistFileDraft, on github: GitHubClient
  ) async throws -> GistFileDraft {
    let size = Gist.File.encodeContent(sent).utf8.count
    for gist in try await github.listGists()
    where (gist.description ?? "") == (draft.newGistName ?? "") && gist.files[draft.filename]?.size == size {
      let remote = try await github.remoteFile(
        gistID: gist.id, ownerID: try ownerID, filename: draft.filename)
      if sourceEqual(remote.content, sent) {
        try updateCache(draft.accountID) {
          $0.insert(remote.gist)
          $0.store(sent, of: draft.filename, in: remote.gist)
        }
        return try await draftStore.confirm(
          draft, gistID: remote.gist.id,
          base: GitHubVersion(text: sent, revision: remote.gist.revision))
      }
    }
    return try await draftStore.forgetSent(draft)
  }

  /// A new day joins the Daily notes gist GitHub has, which the web may have started since this
  /// iPhone last saw the list, and creates one only when there's none. The gist joins the cached
  /// list, so the day finds it before the next refresh even if this publish doesn't land.
  private func joinDailyGist(_ draft: GistFileDraft, on github: GitHubClient) async throws -> GistFileDraft {
    guard let daily = try await github.listGists().first(where: \.isDailyNote) else { return draft }
    try updateCache(draft.accountID) { $0.insert(daily) }
    return try await draftStore.join(draft, gistID: daily.id)
  }
}

extension PublishFailure {
  /// Why a publish that threw `error` didn't land.
  init(_ error: any Error) {
    self =
      switch error {
      case GitHubClientError.http(status: 401), is AccountError: .reconnect
      case GitHubClientError.http(let status): .http(status: status)
      case GitHubClientError.incompleteGist, GitHubClientError.fileTooLarge: .incompleteRemote
      case DraftError.readOnly: .readOnly
      default: .network
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
      eligible: autosaveAllowed && status == .unpublished && hasUnpublishedChanges)
  }

  private var autosaveAllowed: Bool {
    model.isForeground && model.account?.id == file.accountID && model.pendingAccount == nil
      && model.state.loadState == .ready
      && model.account?.preferences.isAutoSaveEnabled == true
      && canMutate && !file.isDeletedOnGitHub
  }

  private func publicationAllowed(reason: PublishReason) -> Bool {
    switch reason {
    case .manual: true
    case .autosave: autosaveAllowed
    case .background:
      model.account?.id == file.accountID && model.pendingAccount == nil
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

  /// Points the file at the gist its publish just cached, so a new note's first publish gives it one.
  private func adoptPublishedGist() {
    guard file.draft?.conflict == nil,
      let gist = model.gistCache?.gists.first(where: { $0.id == file.current.gistID })
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
    if file.draft == nil, file.current.gistID == nil { return model.close(self) }
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
    // Publishing again, as after reconnecting, retries whatever stopped the last publish.
    if reason == .manual { failure = nil }
    if reason != .manual, !hasUnpublishedChanges { return }
    guard canMutate, status.canPublish else { return }
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
      var draft = file.current
      // A new gist or a new day publishes when you ask, even before you type in it.
      if reason == .manual, file.draft == nil, draft.gistID == nil {
        draft = try await model.keep(draft)
      }
      if let result = try await model.publish(draft) { await adopt(result) }
      adoptPublishedGist()
    } catch {
      if !(error is CancellationError || (error as? URLError)?.code == .cancelled) {
        logger.error(
          "Publishing failed: \(String(reflecting: type(of: error)), privacy: .public)")
        failure = PublishFailure(error)
      }
      // The publish may have recorded sent text or found its gist before it stopped.
      if let stored = try? await model.current(file.current) { file.update(stored) }
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
