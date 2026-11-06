import Foundation
import Sync

// Starring, pinning, renaming and deleting go to GitHub in order, after the notes they touch
// are saved on this iPhone.

/// A change to the library, applied in order on GitHub and this iPhone.
public enum Change: Equatable, Sendable {
  case signOut
  case preferences([Preferences.Change])
  case star(gistID: String, starred: Bool)
  case archive(gistID: String, archived: Bool)
  case rename(gistID: String, title: String)
  case renameLocal(Draft, title: String)
  case renameFile(gistID: String, filename: String, newFilename: String)
  case addFile(gistID: String, filename: String)
  case delete(gistID: String)
  case deleteFile(gistID: String, filename: String)
  case fetchRemote(Draft)
  case recordRemote(Draft, remote: String?, revision: String?)
  case discardLocalCopy(Draft)
  case resolveConflict(Conflict, text: String, generation: UInt64)
}

public enum ChangeResult: Sendable {
  case signedOut
  case account(Account)
  case gist(Gist, starred: Bool? = nil)
  case draft(Draft, gist: Gist? = nil)
  case deleted(gistID: String)
  case deletedFile(gistID: String, filename: String, gist: Gist)
  case review(Draft)
  case remoteRead(Draft, RemoteFile?)
  case discardedDraft(UUID)
}

public enum ChangeError: Error, Equatable {
  case invalidTitle
  case invalidFilename
  case filenameExists
  case publicationInProgress
  case staleReview
}

extension ChangeError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidTitle: String(localized: "Enter a name for this gist.")
    case .invalidFilename:
      String(localized: "Enter a Markdown filename ending in .md, without a slash.")
    case .filenameExists: String(localized: "This gist already has a file with that name.")
    case .publicationInProgress: String(localized: "You can change this after the gist publishes.")
    case .staleReview:
      String(localized: "Your draft changed while this review was open. Review the latest draft.")
    }
  }
}

extension Library {
  /// What deleting a row removes: a copy that's only on this iPhone, one day of the daily notes
  /// gist, or the whole gist. Rows the account doesn't own can't be deleted.
  public func deletion(forRow rowID: String) -> Change? {
    guard account != nil, pendingAccount == nil else { return nil }
    let target = rowSelection(for: rowID)
    let draft = target?.draftID.flatMap { id in localDrafts.first { $0.id == id } }
    if let draft,
      draft.gistID.flatMap({ gistID in cachedLibrary?.gists.contains(where: { $0.id == gistID }) }) != true
    {
      return .discardLocalCopy(draft)
    }
    let gistID = target?.gistID ?? draft?.gistID ?? rowID
    guard let gist = cachedLibrary?.owned.first(where: { $0.id == gistID }) else { return nil }
    if gist.isDailyNote, let filename = target?.filename {
      return .deleteFile(gistID: gist.id, filename: filename)
    }
    return .delete(gistID: gist.id)
  }

  /// Re-reads a local discard once publication has settled. If the file reached GitHub after the
  /// confirmation, the confirmed deletion removes it there too. That's only its own file, because a
  /// new day can join the daily notes gist an earlier day created, and `deleteFile` takes the gist
  /// with its last file.
  func settledDeletionAction(
    _ action: Change, confirmedWithoutGist: Bool, accountID: UUID
  ) async throws -> Change {
    guard case .discardLocalCopy(let known) = action else { return action }
    let draft = try await sync.current(known)
    if confirmedWithoutGist, let gistID = draft.gistID {
      return .deleteFile(gistID: gistID, filename: draft.filename)
    }
    return .discardLocalCopy(draft)
  }

  /// Applies a change once the files it touches are saved on this iPhone, holding off typing in
  /// a file it deletes, then brings every open file's details up to date.
  public func apply(_ action: Change, accountID: UUID) async throws -> ChangeResult {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isApplying else { throw ChangeError.publicationInProgress }
    isApplying = true
    var locked: [FileSession] = []
    defer {
      for session in locked { session.endDestructiveAction() }
      isApplying = false
    }
    let confirmedWithoutGist: Bool =
      switch action {
      case .discardLocalCopy(let draft): draft.gistID == nil
      default: false
      }
    do {
      for session in sessions.values {
        let requiresLock: Bool =
          switch action {
          case .delete(let gistID), .deleteFile(let gistID, _):
            session.draft.gistID == gistID
              || localDrafts.contains { $0.id == session.draft.id && $0.gistID == gistID }
          case .discardLocalCopy(let draft): session.draft.id == draft.id
          case .signOut: true
          default: false
          }
        guard requiresLock else { continue }
        switch action {
        case .delete, .deleteFile, .discardLocalCopy:
          await session.waitForPublication()
          try Task.checkCancellation()
          guard account?.id == accountID, pendingAccount == nil else {
            throw AccountError.accountChanged
          }
        default: break
        }
        try session.beginDestructiveAction()
        locked.append(session)
      }
      for session in sessions.values {
        guard await session.waitForLocalSave() else { throw EditError.localPersistenceFailed }
      }
      guard account?.id == accountID, pendingAccount == nil else {
        throw AccountError.accountChanged
      }
      let result = try await perform(
        try await settledDeletionAction(
          action, confirmedWithoutGist: confirmedWithoutGist, accountID: accountID))
      switch result {
      case .gist(let gist, _):
        for session in sessions.values where session.draft.gistID == gist.id {
          let renamed: String? =
            if case .renameFile(_, let filename, let newFilename) = action,
              session.draft.filename == filename
            { newFilename } else { nil }
          try await session.refreshMetadata(gist: gist, filename: renamed)
        }
      case .account:
        for session in sessions.values { try await session.refreshMetadata() }
      case .draft(let draft, let gist):
        try await sessions[draft.id]?.refreshMetadata(gist: gist)
      case .deletedFile(let gistID, _, let gist):
        for session in sessions.values where session.draft.gistID == gistID {
          try await session.refreshMetadata(gist: gist)
        }
      case .signedOut, .deleted, .discardedDraft, .review, .remoteRead:
        break
      }
      return result
    } catch {
      report(error, operation: "action")
      throw error
    }
  }

  /// Applies a change from a tap. A change that doesn't go through is an alert.
  public func run(_ action: Change, accountID: UUID) {
    Task {
      do { _ = try await apply(action, accountID: accountID) } catch {
        openError = error.localizedDescription
      }
    }
  }

  func perform(_ action: Change) async throws -> ChangeResult {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isSigningOut else { throw ChangeError.publicationInProgress }
    if case .signOut = action {
      isSigningOut = true
      libraryRequest = UUID()
    }
    defer {
      if case .signOut = action { isSigningOut = false }
    }
    let result: ChangeResult
    do {
      result = try await sync.perform(action, accountID: account.id)
    } catch {
      if case .signOut = action {
        do {
          if try await sync.cachedAccount() == nil, self.account?.id == account.id {
            reset(to: nil)
          }
        } catch {
          report(error, operation: "confirm-local-sign-out")
        }
      }
      throw error
    }
    guard self.account?.id == account.id else { throw AccountError.accountChanged }
    switch result {
    case .signedOut:
      reset(to: nil)
      return result
    case .account(let updated):
      self.account = updated
      if let cache = cachedLibrary {
        try await sync.cacheLibrary(
          owned: cache.owned, starred: cache.starred, account: updated)
      }
    case .gist(let gist, let starred):
      if var cache = cachedLibrary {
        cache.owned = cache.owned.map { $0.id == gist.id ? gist : $0 }
        cache.starred = cache.starred.map { $0.id == gist.id ? gist : $0 }
        if let starred {
          cache.starred.removeAll { $0.id == gist.id }
          if starred { cache.starred.append(gist) }
        }
        try await sync.cacheLibrary(
          owned: cache.owned, starred: cache.starred, account: account)
      }
    case .draft(let draft, let gist):
      present(File(draft: draft, gist: gist))
    case .deleted(let id):
      let draftIDs = Set(localDrafts.filter { $0.gistID == id }.map(\.id))
      forget(accountID: account.id) {
        $0.gistID == id || $0.draftID.map(draftIDs.contains) == true
      }
      // A refresh that started before the delete would bring the gist back.
      libraryRequest = UUID()
      isRefreshingRemote = false
      if state.loadState == .loading { state.loadState = .ready }
    case .deletedFile(let id, let filename, _):
      forget(accountID: account.id) { $0.gistID == id && $0.filename == filename }
    case .review, .remoteRead:
      break
    case .discardedDraft(let id):
      let discarded = localDrafts.first { $0.id == id }
      forget(accountID: account.id) {
        $0.draftID == id
          || ($0.gistID != nil && $0.gistID == discarded?.gistID
            && $0.filename == discarded?.filename)
      }
      localDrafts.removeAll { $0.id == id }
      projectLibrary()
    }
    try await reloadLocalState(accountID: account.id)
    return result
  }

  /// Closes and forgets the open, opening, failed and remembered file when it no longer exists.
  private func forget(accountID: UUID, where gone: (FileReference) -> Bool) {
    if let loaded = loadedFile, gone(loaded.selection) {
      loadedFile = nil
      state.selectedID = nil
    }
    if let selection = opening?.request.selection, gone(selection) {
      fileRequest = UUID()
      opening = nil
    }
    if let selection = lastOpened.selection(accountID: accountID), gone(selection) {
      lastOpened.clear(accountID: accountID)
    }
    sessions = sessions.filter { !gone($0.value.file.selection) }
  }
}

extension FileSession {
  func beginDestructiveAction() throws {
    guard canMutate, !isPublishing else { throw ChangeError.publicationInProgress }
    isPerformingDestructiveAction = true
    updateEditable()
  }

  func endDestructiveAction() {
    isPerformingDestructiveAction = false
    updateEditable()
  }
}

extension GitHubSync {
  func perform(_ action: Change, accountID: UUID) async throws -> ChangeResult {
    try await mutationQueue.run { try await self.performSerial(action, accountID: accountID) }
  }

  private func performSerial(
    _ action: Change, accountID: UUID
  ) async throws -> ChangeResult {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    switch action {
    case .preferences(let operations):
      return .account(try await accounts.update(operations, accountID: accountID))
    case .signOut:
      try await accounts.signOut(accountID: accountID)
      return .signedOut
    case .discardLocalCopy(let draft):
      try await drafts.discardLocalCopy(id: draft.id, accountID: accountID)
      return .discardedDraft(draft.id)
    case .renameLocal(let draft, let title):
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ChangeError.invalidTitle
      }
      guard draft.accountID == accountID else { throw AccountError.accountChanged }
      let kept = try await drafts.keep(draft)
      guard kept.sentGeneration == nil else { throw ChangeError.publicationInProgress }
      return .draft(
        try await drafts.rename(
          kept.id, accountID: accountID, filename: kept.filename, description: title))
    case .fetchRemote(let draft):
      let current = try await drafts.current(draft)
      guard let gistID = current.gistID else { return .remoteRead(current, nil) }
      let client = await client(accountID: accountID)
      let remote = try await client.remoteFile(
        gistID: gistID, ownerID: current.githubUserID, filename: current.filename)
      try await drafts.cacheGist(remote.gist, accountID: accountID)
      if let content = remote.content {
        try await drafts.cacheContent(
          content, gist: remote.gist, filename: current.filename, accountID: accountID)
      }
      return .remoteRead(current, remote)
    case .recordRemote(let draft, let remote, let revision):
      return .review(
        try await drafts.compareWithGitHub(draft, remote: remote, revision: revision))
    case .resolveConflict(let review, let text, let generation):
      guard review.draft.accountID == accountID else { throw AccountError.accountChanged }
      guard let current = try await drafts.draft(id: review.draft.id, accountID: accountID),
        review.matches(current)
      else { throw ChangeError.staleReview }
      return .review(
        try await drafts.resolveConflict(
          id: current.id, accountID: accountID, expectedGeneration: current.generation,
          text: text, generation: generation))
    case .star(let id, let starred):
      let client = await client(accountID: accountID)
      let gist = try await client.gist(id: id)
      try await client.setStarred(starred, id: id)
      return .gist(gist, starred: starred)
    case .archive(let id, let archived):
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      return .gist(try await client.setArchived(archived, gist: gist))
    case .rename(let id, let title):
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ChangeError.invalidTitle
      }
      let local = try await drafts.drafts(accountID: accountID).filter { $0.gistID == id }
      guard !local.contains(where: { $0.sentGeneration != nil }) else {
        throw ChangeError.publicationInProgress
      }
      let updated = try await client.updateDescription(title, gist: gist)
      for draft in local {
        _ = try await drafts.rename(
          draft.id, accountID: accountID, filename: draft.filename,
          description: updated.description ?? "")
      }
      return .gist(updated)
    case .renameFile(let id, let filename, let newFilename):
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      try Self.validateFilename(newFilename)
      guard filename != newFilename else { return .gist(gist) }
      guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
      guard gist.files[newFilename] == nil else { throw ChangeError.filenameExists }
      let local = try await drafts.drafts(accountID: accountID).filter { $0.gistID == id }
      guard !local.contains(where: { $0.filename == newFilename }) else {
        throw ChangeError.filenameExists
      }
      guard !local.contains(where: { $0.sentGeneration != nil }) else {
        throw ChangeError.publicationInProgress
      }
      let updated = try await client.updateGist(id: id, files: [filename: .rename(newFilename)])
      for draft in local where draft.filename == filename {
        _ = try await drafts.rename(
          draft.id, accountID: accountID, filename: newFilename,
          description: updated.description ?? "")
      }
      return .gist(updated)
    case .addFile(let id, let filename):
      let (client, gist, userID) = try await ownedGist(id: id, account: account)
      try Self.validateFilename(filename)
      guard gist.files[filename] == nil else { throw ChangeError.filenameExists }
      let updated = try await client.updateGist(id: id, files: [filename: .content("")])
      try await drafts.cacheGist(updated, accountID: accountID)
      try await drafts.cacheContent("", gist: updated, filename: filename, accountID: accountID)
      let draft = Draft(
        accountID: accountID, githubUserID: userID, gist: updated, filename: filename, text: "")
      return .draft(draft, gist: updated)
    case .delete(let id):
      let (client, _, _) = try await ownedGist(id: id, account: account)
      return try await deleteGist(id, client: client, accountID: accountID)
    case .deleteFile(let id, let filename):
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      let isLastRemoteFile = gist.files[filename] != nil && gist.files.count == 1
      if isLastRemoteFile {
        // GitHub can't leave a gist without files, so deleting the last file deletes the gist.
        return try await deleteGist(id, client: client, accountID: accountID)
      }
      // A file that's already gone from GitHub only needs its copy on this iPhone removed.
      let updated =
        gist.files[filename] == nil
        ? gist : try await client.updateGist(id: id, files: [filename: .delete])
      try await drafts.removeDrafts(
        gistID: id, filename: filename, updated: updated, accountID: accountID)
      return .deletedFile(gistID: id, filename: filename, gist: updated)
    }
  }

  private func deleteGist(
    _ id: String, client: GitHubClient, accountID: UUID
  ) async throws -> ChangeResult {
    try await client.deleteGist(id: id)
    try await drafts.removeDrafts(gistID: id, accountID: accountID)
    return .deleted(gistID: id)
  }

  private func ownedGist(
    id: String, account: Account
  ) async throws -> (GitHubClient, Gist, Int64) {
    let client = await client(accountID: account.id)
    let gist = try await client.gist(id: id)
    guard let userID = account.githubUserID, gist.owner?.id == userID else {
      throw DraftError.readOnly
    }
    return (client, gist, userID)
  }

  private static func validateFilename(_ filename: String) throws {
    guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      filename.hasSuffix(".md"), !filename.contains("/"), !filename.contains("\0")
    else { throw ChangeError.invalidFilename }
  }
}
