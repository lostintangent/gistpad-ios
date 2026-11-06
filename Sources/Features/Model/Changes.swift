import Foundation
import Store

// Starring, pinning, renaming and deleting go to GitHub one at a time, after the notes they touch
// are saved on this iPhone.

/// What deleting a row or an open file removes.
public enum Deletion: Equatable, Sendable {
  /// A gist that's only on this iPhone, or a recovered copy of a file.
  case localCopy(Draft)
  /// One day of the daily notes gist.
  case file(gistID: String, filename: String)
  case gist(id: String)
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

extension GistPadModel {
  /// What deleting a row removes. Rows the account doesn't own can't be deleted.
  public func deletion(forRow rowID: String) -> Deletion? {
    guard account != nil, pendingAccount == nil else { return nil }
    let target = rowSelection(for: rowID)
    let draft = target?.draftID.flatMap { id in localDrafts.first { $0.id == id } }
    if let draft,
      draft.gistID.flatMap({ gistID in gistCache?.gists.contains(where: { $0.id == gistID }) }) != true
    {
      return .localCopy(draft)
    }
    let gistID = target?.gistID ?? draft?.gistID ?? rowID
    guard let gist = gistCache?.owned.first(where: { $0.id == gistID }) else { return nil }
    if gist.isDailyNote, let filename = target?.filename {
      return .file(gistID: gist.id, filename: filename)
    }
    return .gist(id: gist.id)
  }

  /// Saves pins, tags, the accent color and settings with your account.
  public func updatePreferences(_ changes: [GistPadPreferences.Change]) async throws {
    try await change { account in
      let updated = try await sync.serially { sync in
        try await sync.accounts.update(changes, accountID: account.id)
      }
      self.account = updated
      for fileEditor in editors.values { try await fileEditor.refreshMetadata() }
    }
  }

  public func setStarred(_ starred: Bool, gistID: String) async throws {
    try await change { account in
      let gist = try await sync.serially { sync in
        let client = await sync.client(accountID: account.id)
        let gist = try await client.gist(id: gistID)
        try await client.setStarred(starred, id: gistID)
        return gist
      }
      try await landed(gist, starred: starred)
    }
  }

  public func setArchived(_ archived: Bool, gistID: String) async throws {
    try await change { account in
      try await landed(
        try await sync.serially { sync in
          let (client, gist, _) = try await sync.ownedGist(gistID, account: account)
          return try await client.setArchived(archived, gist: gist)
        })
    }
  }

  /// Renames a gist on GitHub, or names a new one that's only on this iPhone.
  public func rename(_ draft: Draft, to title: String) async throws {
    if let gistID = draft.gistID { return try await rename(gistID: gistID, to: title) }
    try Self.validateTitle(title)
    try await change { _ in
      let renamed = try await sync.serially { sync in
        let kept = try await sync.drafts.keep(draft)
        guard kept.sentGeneration == nil else { throw ChangeError.publicationInProgress }
        return try await sync.drafts.rename(
          kept.id, accountID: kept.accountID, filename: kept.filename, description: title)
      }
      present(GistFile(draft: renamed, gist: nil))
      try await editors[renamed.id]?.refreshMetadata()
    }
  }

  /// Renames a gist on GitHub and its drafts on this iPhone.
  public func rename(gistID: String, to title: String) async throws {
    try Self.validateTitle(title)
    try await change { account in
      try await landed(
        try await sync.serially { sync in
          let (client, gist, _) = try await sync.ownedGist(gistID, account: account)
          let local = try await sync.unsentDrafts(gistID: gistID, accountID: account.id)
          let updated = try await client.updateDescription(title, gist: gist)
          for draft in local {
            _ = try await sync.drafts.rename(
              draft.id, accountID: account.id, filename: draft.filename,
              description: updated.description ?? "")
          }
          return updated
        })
    }
  }

  public func renameFile(_ filename: String, to newFilename: String, gistID: String) async throws {
    try Self.validateFilename(newFilename)
    try await change { account in
      let gist = try await sync.serially { sync in
        let (client, gist, _) = try await sync.ownedGist(gistID, account: account)
        guard filename != newFilename else { return gist }
        guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
        let local = try await sync.unsentDrafts(gistID: gistID, accountID: account.id)
        guard gist.files[newFilename] == nil, !local.contains(where: { $0.filename == newFilename })
        else { throw ChangeError.filenameExists }
        let updated = try await client.updateGist(
          id: gistID, files: [filename: .rename(newFilename)])
        for draft in local where draft.filename == filename {
          _ = try await sync.drafts.rename(
            draft.id, accountID: account.id, filename: newFilename,
            description: updated.description ?? "")
        }
        return updated
      }
      try await landed(gist, renamedFile: (filename, newFilename))
    }
  }

  /// Adds an empty Markdown file to a gist and opens it.
  public func addFile(_ filename: String, to gistID: String) async throws {
    try Self.validateFilename(filename)
    try await change { account in
      let (draft, gist) = try await sync.serially { sync in
        let (client, gist, userID) = try await sync.ownedGist(gistID, account: account)
        guard gist.files[filename] == nil else { throw ChangeError.filenameExists }
        let updated = try await client.updateGist(id: gistID, files: [filename: .content("")])
        try await sync.drafts.cacheGist(updated, accountID: account.id)
        try await sync.drafts.cacheContent(
          "", gist: updated, filename: filename, accountID: account.id)
        let draft = Draft(
          accountID: account.id, githubUserID: userID, gist: updated, filename: filename, text: "")
        return (draft, updated)
      }
      present(GistFile(draft: draft, gist: gist))
      try await editors[draft.id]?.refreshMetadata(gist: gist)
    }
  }

  /// Deletes what you confirmed once any publish of it settles. A copy that reached GitHub after
  /// you confirmed is deleted there too, but only its own file, because a new day can join the
  /// daily notes gist an earlier day created.
  public func delete(_ deletion: Deletion) async throws {
    try await change(locking: { fileEditor in
      switch deletion {
      case .localCopy(let draft): fileEditor.draft.id == draft.id
      case .file(let gistID, _), .gist(let gistID):
        fileEditor.draft.gistID == gistID
          || localDrafts.contains { $0.id == fileEditor.draft.id && $0.gistID == gistID }
      }
    }) { account in
      switch deletion {
      case .localCopy(let confirmed):
        let draft = try await sync.current(confirmed)
        if confirmed.gistID == nil, let gistID = draft.gistID {
          return try await deleteFile(draft.filename, gistID: gistID, account: account)
        }
        try await sync.serially { sync in
          try await sync.drafts.discardLocalCopy(id: draft.id, accountID: draft.accountID)
        }
        forget(accountID: account.id) {
          $0.draftID == draft.id
            || ($0.gistID != nil && $0.gistID == draft.gistID && $0.filename == draft.filename)
        }
        localDrafts.removeAll { $0.id == draft.id }
        projectLibrary()
      case .file(let gistID, let filename):
        try await deleteFile(filename, gistID: gistID, account: account)
      case .gist(let id):
        try await sync.serially { sync in
          let (client, _, _) = try await sync.ownedGist(id, account: account)
          try await client.deleteGist(id: id)
          try await sync.drafts.removeDrafts(gistID: id, accountID: account.id)
        }
        forgetGist(id, accountID: account.id)
      }
    }
  }

  /// Signs out once every open note is saved on this iPhone.
  public func signOut() async throws {
    try await change(locking: { _ in true }) { account in
      isSigningOut = true
      libraryRequest = UUID()
      defer { isSigningOut = false }
      do {
        try await sync.serially { sync in try await sync.accounts.signOut(accountID: account.id) }
      } catch {
        // A sign-out that already removed this iPhone's session still signs you out here.
        if try await sync.cachedAccount() == nil, self.account?.id == account.id {
          reset(to: nil)
        }
        throw error
      }
      reset(to: nil)
    }
  }

  /// Runs a change from a tap. One that doesn't go through is an alert.
  public func run(_ change: @escaping @MainActor () async throws -> Void) {
    Task {
      do { try await change() } catch { openError = error.localizedDescription }
    }
  }

  /// Runs one change at a time, once every open note is saved on this iPhone, then reloads what's
  /// saved here. Typing pauses in the notes it `locks` until it lands.
  private func change(
    locking locks: (GistFileEditor) -> Bool = { _ in false },
    _ body: @MainActor (GistPadAccount) async throws -> Void
  ) async throws {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isApplying else { throw ChangeError.publicationInProgress }
    isApplying = true
    var locked: [GistFileEditor] = []
    defer {
      for fileEditor in locked { fileEditor.endDestructiveAction() }
      isApplying = false
    }
    do {
      for fileEditor in editors.values where locks(fileEditor) && fileEditor.details.access.canEdit {
        await fileEditor.waitForPublication()
        try fileEditor.beginDestructiveAction()
        locked.append(fileEditor)
      }
      for fileEditor in editors.values {
        guard await fileEditor.waitForLocalSave() else { throw EditError.localPersistenceFailed }
      }
      try Task.checkCancellation()
      guard self.account?.id == account.id, pendingAccount == nil else {
        throw AccountError.accountChanged
      }
      try await body(account)
      if self.account?.id == account.id { try await reloadLocalState(accountID: account.id) }
    } catch {
      report(error, operation: "change")
      throw error
    }
  }

  /// Takes a gist GitHub just changed into the cache and every note open in it.
  private func landed(
    _ gist: Gist, starred: Bool? = nil, renamedFile: (from: String, to: String)? = nil
  ) async throws {
    if var cache = gistCache, let account {
      cache.owned = cache.owned.map { $0.id == gist.id ? gist : $0 }
      cache.starred = cache.starred.map { $0.id == gist.id ? gist : $0 }
      if let starred {
        cache.starred.removeAll { $0.id == gist.id }
        if starred { cache.starred.append(gist) }
      }
      try await sync.cacheGists(owned: cache.owned, starred: cache.starred, accountID: account.id)
    }
    for fileEditor in editors.values where fileEditor.draft.gistID == gist.id {
      try await fileEditor.refreshMetadata(
        gist: gist, filename: fileEditor.draft.filename == renamedFile?.from ? renamedFile?.to : nil)
    }
  }

  /// Deletes one file. GitHub can't keep a gist without files, so the last one takes the gist.
  private func deleteFile(_ filename: String, gistID: String, account: GistPadAccount) async throws {
    let left = try await sync.serially { sync -> Gist? in
      let (client, gist, _) = try await sync.ownedGist(gistID, account: account)
      if gist.files[filename] != nil, gist.files.count == 1 {
        try await client.deleteGist(id: gistID)
        try await sync.drafts.removeDrafts(gistID: gistID, accountID: account.id)
        return nil
      }
      // A file that's already gone from GitHub only needs its copy on this iPhone removed.
      let updated =
        gist.files[filename] == nil
        ? gist : try await client.updateGist(id: gistID, files: [filename: .delete])
      try await sync.drafts.removeDrafts(
        gistID: gistID, filename: filename, updated: updated, accountID: account.id)
      return updated
    }
    guard let left else { return forgetGist(gistID, accountID: account.id) }
    forget(accountID: account.id) { $0.gistID == gistID && $0.filename == filename }
    for fileEditor in editors.values where fileEditor.draft.gistID == gistID {
      try await fileEditor.refreshMetadata(gist: left)
    }
  }

  private func forgetGist(_ id: String, accountID: UUID) {
    let draftIDs = Set(localDrafts.filter { $0.gistID == id }.map(\.id))
    forget(accountID: accountID) { $0.gistID == id || $0.draftID.map(draftIDs.contains) == true }
    // A refresh that started before the delete would bring the gist back.
    libraryRequest = UUID()
    isRefreshingRemote = false
    if state.loadState == .loading { state.loadState = .ready }
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
    editors = editors.filter { !gone($0.value.file.selection) }
  }
}

extension GistFileEditor {
  /// What Delete on this file's screen removes, the same as its row in the list.
  public var deletion: Deletion? {
    if file.isRecovery || draft.gistID == nil { return .localCopy(draft) }
    guard let gist = file.gist, details.access.canEdit else { return nil }
    return gist.isDailyNote ? .file(gistID: gist.id, filename: file.filename) : .gist(id: gist.id)
  }

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

extension GistPadModel {
  private static func validateTitle(_ title: String) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChangeError.invalidTitle
    }
  }

  private static func validateFilename(_ filename: String) throws {
    guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      filename.hasSuffix(".md"), !filename.contains("/"), !filename.contains("\0")
    else { throw ChangeError.invalidFilename }
  }
}

extension GitHubSync {
  /// A gist the account owns, read fresh from GitHub before changing it.
  func ownedGist(_ id: String, account: GistPadAccount) async throws -> (GitHubClient, Gist, Int64) {
    let client = await client(accountID: account.id)
    let gist = try await client.gist(id: id)
    guard let userID = account.githubUserID, gist.owner?.id == userID else {
      throw DraftError.readOnly
    }
    return (client, gist, userID)
  }

  /// A gist's drafts on this iPhone, which a rename carries along. One that's publishing would
  /// land under the old name.
  func unsentDrafts(gistID: String, accountID: UUID) async throws -> [Draft] {
    let local = try await drafts.drafts(accountID: accountID).filter { $0.gistID == gistID }
    guard !local.contains(where: { $0.sentGeneration != nil }) else {
      throw ChangeError.publicationInProgress
    }
    return local
  }
}
