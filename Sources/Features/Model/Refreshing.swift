import Editor
import Foundation
import Screens
import Store

// The list and the open note read GitHub as they appear, at most every five minutes, so the
// web's edits show up without a pull.

public struct RemoteReadProblem: Equatable {
  public enum Recovery: Equatable { case retry, reconnect }

  let message: String
  public var recovery: Recovery = .retry

  func status(heading: String, detail: String?) -> GitHubStatusState {
    let recoveryTitle = switch recovery {
    case .retry: String(localized: "Try Again")
    case .reconnect: String(localized: "Reconnect GitHub")
    }
    return .problem(
      .init(
        heading: heading, message: message, recoveryTitle: recoveryTitle, detail: detail))
  }
}

@MainActor
public enum RemoteRead {
  /// The problem a failed GitHub read shows, or nil when a newer request superseded it.
  static func problem(for error: any Error) -> RemoteReadProblem? {
    if error is CancellationError || (error as? URLError)?.code == .cancelled
      || (error as? DraftError) == .staleGeneration
      || (error as? ChangeError) == .staleReview
    {
      return nil
    }
    if needsReconnect(error) {
      return .init(
        message: String(localized: "Reconnect GitHub to check for changes."), recovery: .reconnect)
    }
    return .init(message: error.localizedDescription)
  }

  static func needsReconnect(_ error: any Error) -> Bool {
    if let error = error as? AccountError {
      return error == .signedOut || error == .reconnectGitHub || error == .accountChanged
    }
    if case .http(401)? = error as? GitHubClientError { return true }
    return false
  }
}

extension GistPadModel {
  public var remoteRefreshStatus: GitHubStatusState {
    if let problem = remoteRefreshProblem, gistCache != nil || !localDrafts.isEmpty {
      return problem.status(
        heading: String(localized: "Couldn't update your gists"),
        detail: String(localized: "Your gists on this iPhone are unchanged."))
    }
    return isRefreshingRemote
      ? .checking(operation: String(localized: "Checking GitHub for changes")) : .idle
  }

  // Supabase only supplies preferences, so GitHub reads keep going when its refresh fails. A missing GitHub token still needs reconnecting.
  private func refreshedAccount() async throws -> GistPadAccount {
    do {
      return try await accountStore.refreshAccount()
    } catch {
      if error is CancellationError || (error as? AccountError) == .reconnectGitHub { throw error }
      guard let connected = try await accountStore.connectedAccount() else { throw error }
      return connected
    }
  }

  /// The list and each file read GitHub again only once their last read is five minutes old. A
  /// failed read leaves no time, so the next chance tries again.
  static func isStale(_ refreshedAt: Date?) -> Bool {
    refreshedAt.map { $0.timeIntervalSinceNow < -5 * 60 } ?? true
  }

  /// Refreshes as the app comes back, like the web on focus, when the list is stale or leaving cut
  /// its refresh off.
  public func refreshOnReturn() async {
    guard account != nil, !isStarting, isRefreshingRemote || Self.isStale(refreshedAt) else {
      return
    }
    await refresh()
  }

  public func refresh() async {
    guard pendingAccount == nil, !isSigningOut else { return }
    guard let account else {
      await start()
      return
    }
    let request = UUID()
    libraryRequest = request
    let previousState: LibraryLoadState = state.loadState == .loading ? .ready : state.loadState
    isRefreshingRemote = true
    // A retry shows as checking instead of the problem it may be about to clear.
    remoteRefreshProblem = nil
    defer {
      if request == libraryRequest { isRefreshingRemote = false }
    }
    state.loadState = .loading
    do {
      let refreshed = try await refreshedAccount()
      guard refreshed.id == account.id else { throw AccountError.accountChanged }
      let github = await client(accountID: account.id)
      async let ownedGists = github.listGists()
      async let starredGists = github.listStarredGists()
      let (owned, starred) = try await (ownedGists, starredGists)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      try await draftStore.cacheGists(owned: owned, starred: starred, accountID: account.id)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      self.account = refreshed
      state.loadState = .ready
      await refreshToday(in: owned, accountID: account.id)
      try await reloadLocalState(accountID: account.id)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      refreshedAt = .now
    } catch {
      guard request == libraryRequest else { return }
      // A failed refresh leaves the list stale, so returning to the app tries again.
      refreshedAt = nil
      // A request that only timed out or lost its connection keeps your gists on screen without
      // a problem, and the next refresh tries again. With nothing cached, the failure explains itself.
      let wasDropped = (error as? URLError).map {
        [URLError.Code.timedOut, .networkConnectionLost].contains($0.code)
      } ?? false
      guard let problem = RemoteRead.problem(for: error), !(wasDropped && gistCache != nil)
      else {
        state.loadState = previousState
        return
      }
      report(error, operation: "refresh")
      remoteRefreshProblem = problem
      state.loadState =
        problem.recovery == .reconnect
        ? .reconnectRequired(message: error.localizedDescription)
        : .failed(message: error.localizedDescription)
    }
  }
}

extension GistFileEditor {
  public var remoteInspectionStatus: GitHubStatusState {
    guard let problem = remoteInspectionProblem else { return .idle }
    switch saveState {
    case .failed, .conflict, .reconnect:
      return .idle
    default:
      return problem.status(
        heading: String(localized: "Couldn't check for updates"), detail: nil)
    }
  }

  /// Reads this note from GitHub as it opens or the app comes back. A note you haven't typed in
  /// takes GitHub's newer text, and one with edits shows the conflict.
  public func inspectRemoteChanges() async {
    guard GistPadModel.isStale(refreshedAt), !isInspectingRemote, !isPublishing, canMutate,
      !file.isRecovery, draft.gistID != nil,
      model.account?.id == draft.accountID, model.pendingAccount == nil
    else { return }
    if case .conflict = draft.state { return }
    isInspectingRemote = true
    defer { isInspectingRemote = false }
    guard await waitForLocalSave() else { return }
    let generation = editor.generation
    do {
      let github = await model.client(accountID: draft.accountID)
      let store = model.draftStore
      let (current, remote) = try await model.serially {
        let current = try await store.current(draft)
        guard let gistID = current.gistID else { return (current, RemoteFile?.none) }
        let remote = try await github.remoteFile(
          gistID: gistID, ownerID: current.githubUserID, filename: current.filename)
        try await store.cacheGist(remote.gist, accountID: current.accountID)
        if let content = remote.content {
          try await store.cacheContent(
            content, gist: remote.gist, filename: current.filename, accountID: current.accountID)
        }
        return (current, remote)
      }
      try await model.reloadLocalState(accountID: current.accountID)
      guard let remote, current.id == draft.id, current.generation == generation,
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
      } else {
        adopt(
          try await model.serially {
            try await store.compareWithGitHub(
              current, remote: remote.content, revision: remote.gist.revision)
          })
        try await model.reloadLocalState(accountID: current.accountID)
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
}
