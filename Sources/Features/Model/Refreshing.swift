import Editor
import Foundation
import Screens
import Store

// The list and the open note read GitHub as they appear, at most every five minutes, so the
// web's edits show up without a pull.

extension GistPadModel {
  public var refreshStatus: GitHubStatus {
    if let problem {
      return .problem(
        problem, heading: String(localized: "Couldn't check for changes"),
        detail: String(localized: "Your gists on this iPhone are unchanged."))
    }
    return phase == .refreshing
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
  func refreshOnReturn() async {
    guard account != nil, phase != .loading, phase == .refreshing || Self.isStale(refreshedAt) else {
      return
    }
    await refresh()
  }

  /// A change on this iPhone supersedes a list read already on its way, which would undo it.
  func supersedeRefresh() {
    libraryRequest = UUID()
    if phase == .loading || phase == .refreshing { phase = .ready }
  }

  public func refresh() async {
    guard !phase.isChangingAccount else { return }
    guard let account else {
      await start()
      return
    }
    let request = UUID()
    libraryRequest = request
    phase = .refreshing
    // A retry shows as checking instead of the problem it may be about to clear.
    problem = nil
    defer {
      if request == libraryRequest, phase == .refreshing { phase = .ready }
    }
    do {
      let refreshed = try await refreshedAccount()
      guard refreshed.id == account.id else { throw AccountError.accountChanged }
      let github = await client(accountID: account.id)
      async let ownedGists = github.listGists()
      async let starredGists = github.listStarredGists()
      let (owned, starred) = try await (ownedGists, starredGists)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      var cache = try cache(account.id) ?? GistCache(accountID: account.id)
      cache.replaceLists(owned: owned, starred: starred)
      try save(cache)
      self.account = refreshed
      await refreshToday(in: cache.owned, accountID: account.id)
      try await reloadLocalState(accountID: account.id)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      refreshedAt = .now
    } catch {
      guard request == libraryRequest else { return }
      // A failed refresh leaves the list stale, so returning to the app tries again.
      refreshedAt = nil
      // A request that only timed out or lost its connection keeps your gists on screen without
      // a problem, and the next refresh tries again. With nothing cached, the failure explains itself.
      let code = (error as? URLError)?.code
      let wasDropped = code == .timedOut || code == .networkConnectionLost
      guard !(error is CancellationError || code == .cancelled), !(wasDropped && gistCache != nil)
      else { return }
      report(error, operation: "refresh")
      problem = GitHubProblem(error)
    }
  }
}

extension GistFileEditor {
  public var refreshStatus: GitHubStatus {
    guard let problem = refreshProblem else { return .idle }
    switch status {
    case .failed, .conflict:
      return .idle
    default:
      return .problem(problem, heading: String(localized: "Couldn't check for changes"))
    }
  }

  /// Reads this note from GitHub as it opens or the app comes back. A note you haven't typed in
  /// takes GitHub's newer text, and one with edits shows the conflict.
  public func refresh() async {
    guard GistPadModel.isStale(refreshedAt), !isRefreshing, !isPublishing, canEdit,
      !file.isDeletedOnGitHub, let gistID = file.gistID, file.draft?.conflict == nil,
      model.account?.id == file.accountID
    else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    guard await waitForLocalSave() else { return }
    let generation = editor.generation
    let read = file.nextDraft
    do {
      let ownerID = try model.ownerID
      let github = await model.client(accountID: read.accountID)
      let (stored, latest) = try await model.serially {
        let stored = try await model.current(read)
        let current = stored ?? read
        let latest = try await github.file(
          gistID: gistID, ownerID: ownerID, filename: current.filename)
        try model.cache(latest, filename: current.filename, accountID: current.accountID)
        return (stored, latest)
      }
      try await model.reloadLocalState(accountID: read.accountID)
      guard editor.generation == generation, !isPublishing, canEdit else { return }
      if let stored {
        // The store refuses this if you typed after the fetch.
        await adopt(
          try await model.serially {
            try await model.draftStore.compareWithGitHub(
              stored, text: latest.content, revision: latest.gist.revision)
          })
        try await model.reloadLocalState(accountID: read.accountID)
      } else if let content = latest.content, !sourceEqual(content, read.text) {
        // Every text change bumps the generation, so this is refused if you typed after the fetch.
        try await commitMutation(
          Edit(
            range: NSRange(location: 0, length: editor.text.utf16.count),
            expected: editor.text, replacement: content),
          expectedGeneration: generation
        ) { read.adopting(GitHubVersion(text: content, revision: latest.gist.revision)) }
      }
      refreshProblem = nil
      refreshedAt = .now
    } catch {
      logger.error(
        "Refresh failed: \(String(reflecting: type(of: error)), privacy: .public)")
      refreshProblem = GitHubProblem(error) == .reconnect ? .reconnect : nil
    }
  }
}
