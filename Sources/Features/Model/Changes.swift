import Foundation
import Store

// Starring, pinning, renaming and deleting go to GitHub one at a time, after the notes they touch
// are saved on this iPhone.

/// What deleting a row or an open file removes.
public enum Deletion: Equatable, Sendable {
  /// A gist that's only on this iPhone, or a recovered copy of a file.
  case localCopy(GistFileDraft)
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
    guard account != nil, phase.switchingTo == nil else { return nil }
    if let draft = draft(forRow: rowID),
      draft.gistID.flatMap({ gistID in gistCache?.gists.contains(where: { $0.id == gistID }) }) != true
    {
      return .localCopy(draft)
    }
    guard case .gist(let gistID, let filename, _) = request(forRow: rowID),
      let gist = gistCache?.owned.first(where: { $0.id == gistID })
    else { return nil }
    if gist.isDailyNote, let filename { return .file(gistID: gist.id, filename: filename) }
    return .gist(id: gist.id)
  }

  /// Saves pins, tags, the accent color and settings with your account.
  public func updatePreferences(_ changes: [GistPadPreferences.Change]) async throws {
    try await change { account in
      let updated = try await serially {
        try await accountStore.update(changes, accountID: account.id)
      }
      self.account = updated
      for fileEditor in editors.values { try await fileEditor.refreshMetadata() }
    }
  }

  public func setStarred(_ starred: Bool, gistID: String) async throws {
    try await change { account in
      let github = await client(accountID: account.id)
      let gist = try await serially {
        let gist = try await github.gist(id: gistID)
        try await github.setStarred(starred, id: gistID)
        return gist
      }
      try await landed(gist, starred: starred)
    }
  }

  public func setArchived(_ archived: Bool, gistID: String) async throws {
    try await change { account in
      try await landed(
        try await serially {
          let (github, gist) = try await ownedGist(gistID, account: account)
          return try await github.setArchived(archived, gist: gist)
        })
    }
  }

  /// Renames a gist on GitHub, or names a new one that's only on this iPhone.
  /// Renames a file's gist: on GitHub once it has one, else the new gist you're writing.
  public func rename(_ draft: GistFileDraft, to title: String) async throws {
    if let gistID = draft.gistID { return try await renameGist(gistID, to: title) }
    try Self.validateTitle(title)
    try await change { _ in
      let renamed = try await serially {
        guard try await draftStore.current(draft)?.sent == nil else {
          throw ChangeError.publicationInProgress
        }
        return try await draftStore.rename(draft, newGistName: title)
      }
      present(GistFile(draft: renamed, gist: nil))
      try await editors[renamed.id]?.refreshMetadata()
    }
  }

  /// Renames a gist on GitHub and its drafts on this iPhone.
  private func renameGist(_ gistID: String, to title: String) async throws {
    try Self.validateTitle(title)
    try await change { account in
      try await landed(
        try await serially {
          let (github, gist) = try await ownedGist(gistID, account: account)
          let local = try await unsentDrafts(gistID: gistID, accountID: account.id)
          let updated = try await github.updateDescription(title, gist: gist)
          for draft in local where draft.newGistName != nil {
            _ = try await draftStore.rename(draft, newGistName: updated.description ?? "")
          }
          return updated
        })
    }
  }

  public func renameFile(_ draft: GistFileDraft, to newFilename: String) async throws {
    guard let gistID = draft.gistID else { throw GistLinks.Error.notPublished }
    let filename = draft.filename
    try Self.validateFilename(newFilename)
    try await change { account in
      let gist = try await serially {
        let (github, gist) = try await ownedGist(gistID, account: account)
        guard filename != newFilename else { return gist }
        guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
        let local = try await unsentDrafts(gistID: gistID, accountID: account.id)
        guard gist.files[newFilename] == nil, !local.contains(where: { $0.filename == newFilename })
        else { throw ChangeError.filenameExists }
        let updated = try await github.updateGist(
          id: gistID, files: [filename: .rename(newFilename)])
        for draft in local where draft.filename == filename {
          _ = try await draftStore.rename(draft, filename: newFilename)
        }
        return updated
      }
      try await landed(gist, renamedFile: (filename, newFilename))
    }
  }

  /// Adds an empty Markdown file to a gist and opens it.
  public func addFile(named filename: String, to gistID: String) async throws {
    try Self.validateFilename(filename)
    try await change { account in
      let gist = try await serially {
        let (github, gist) = try await ownedGist(gistID, account: account)
        guard gist.files[filename] == nil else { throw ChangeError.filenameExists }
        let updated = try await github.updateGist(id: gistID, files: [filename: .content("")])
        try updateCache(account.id) {
          $0.update(updated)
          $0.store("", of: filename, in: updated)
        }
        return updated
      }
      let file = GistFile(
        accountID: account.id, gist: gist, filename: filename,
        published: GitHubVersion(text: "", revision: gist.revision))
      present(file)
      try await editors[file.id]?.refreshMetadata(gist: gist)
    }
  }

  /// Deletes what you confirmed once any publish of it settles. A copy that reached GitHub after
  /// you confirmed is deleted there too, but only its own file, because a new day can join the
  /// daily notes gist an earlier day created.
  public func delete(_ deletion: Deletion) async throws {
    try await change(locking: { fileEditor in
      switch deletion {
      case .localCopy(let draft): fileEditor.file.id == draft.id
      case .file(let gistID, _), .gist(let gistID):
        fileEditor.file.gistID == gistID
          || drafts.contains { $0.id == fileEditor.file.id && $0.gistID == gistID }
      }
    }) { account in
      switch deletion {
      case .localCopy(let confirmed):
        let draft = try await current(confirmed) ?? confirmed
        if confirmed.gistID == nil, let gistID = draft.gistID ?? publishedGistIDs[draft.id] {
          return try await deleteFile(draft.filename, gistID: gistID, account: account)
        }
        try await serially {
          try await draftStore.discardLocalCopy(id: draft.id, accountID: draft.accountID)
        }
        forget(gistID: draft.gistID, filename: draft.filename, drafts: [draft.id], accountID: account.id)
        drafts.removeAll { $0.id == draft.id }
        projectLibrary()
      case .file(let gistID, let filename):
        try await deleteFile(filename, gistID: gistID, account: account)
      case .gist(let id):
        try await serially {
          let (github, _) = try await ownedGist(id, account: account)
          try await github.deleteGist(id: id)
          try updateCache(account.id) { $0.remove(gistID: id) }
          try await draftStore.removeDrafts(gistID: id, accountID: account.id)
        }
        forgetGist(id, accountID: account.id)
      }
    }
  }

  /// Signs out once every open note is saved on this iPhone.
  public func signOut() async throws {
    try await change(locking: { _ in true }) { account in
      phase = .signingOut
      libraryRequest = UUID()
      defer { if phase == .signingOut { phase = .ready } }
      do {
        try await serially { try await accountStore.signOut(accountID: account.id) }
      } catch {
        // A sign-out that already removed this iPhone's session still signs you out here.
        if try await accountStore.cachedAccount() == nil, self.account?.id == account.id {
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
    guard let account, phase.switchingTo == nil else { throw AccountError.accountChanged }
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
      guard self.account?.id == account.id, phase.switchingTo == nil else {
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
    if let account {
      try updateCache(account.id) { cache in
        cache.update(gist)
        if let starred { cache.setStarred(starred, gist) }
      }
    }
    for fileEditor in editors.values where fileEditor.file.gistID == gist.id {
      try await fileEditor.refreshMetadata(
        gist: gist, filename: fileEditor.file.filename == renamedFile?.from ? renamedFile?.to : nil)
    }
  }

  /// Deletes one file. GitHub can't keep a gist without files, so the last one takes the gist.
  private func deleteFile(_ filename: String, gistID: String, account: GistPadAccount) async throws {
    let left = try await serially { () -> Gist? in
      let (github, gist) = try await ownedGist(gistID, account: account)
      if gist.files[filename] != nil, gist.files.count == 1 {
        try await github.deleteGist(id: gistID)
        try updateCache(account.id) { $0.remove(gistID: gistID) }
        try await draftStore.removeDrafts(gistID: gistID, accountID: account.id)
        return nil
      }
      // A file that's already gone from GitHub only needs its copy on this iPhone removed.
      let updated =
        gist.files[filename] == nil
        ? gist : try await github.updateGist(id: gistID, files: [filename: .delete])
      try updateCache(account.id) { $0.remove(gistID: gistID, filename: filename, updated: updated) }
      try await draftStore.removeDrafts(gistID: gistID, filename: filename, accountID: account.id)
      return updated
    }
    guard let left else { return forgetGist(gistID, accountID: account.id) }
    forget(gistID: gistID, filename: filename, accountID: account.id)
    for fileEditor in editors.values where fileEditor.file.gistID == gistID {
      try await fileEditor.refreshMetadata(gist: left)
    }
  }

  private func forgetGist(_ id: String, accountID: UUID) {
    let draftIDs = Set(drafts.filter { $0.gistID == id }.map(\.id))
    forget(gistID: id, drafts: draftIDs, accountID: accountID)
    // A refresh that started before the delete would bring the gist back.
    supersedeRefresh()
  }

  /// Closes and forgets the open, opening, failed and remembered file once it's gone: `filename`
  /// in the gist, or every file of it when `filename` is nil, and the drafts in `drafts`.
  private func forget(
    gistID: String?, filename: String? = nil, drafts: Set<UUID> = [], accountID: UUID
  ) {
    func gone(_ request: Opening.Request) -> Bool {
      switch request {
      case .gist(let id, let name, _): id == gistID && (filename == nil || name == filename)
      case .draft(let id, _): drafts.contains(id)
      case .today, .new: false
      }
    }
    if let loaded = loadedFile, gone(loaded.request) {
      loadedFile = nil
      state.selectedID = nil
    }
    if let request = opening?.request, gone(request) {
      fileRequest = UUID()
      opening = nil
    }
    if let saved = lastOpened(accountID: accountID), gone(saved) {
      defaults.removeObject(forKey: Self.lastOpenedKey(accountID))
    }
    editors = editors.filter { !gone($0.value.file.request) }
  }
}

extension GistFileEditor {
  /// What Delete on this file's screen removes, the same as its row in the list.
  public var deletion: Deletion? {
    if file.isDeletedOnGitHub || file.gistID == nil { return .localCopy(file.nextDraft) }
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

extension GistPadModel {
  /// A gist the account owns, read fresh from GitHub before changing it.
  private func ownedGist(
    _ id: String, account: GistPadAccount
  ) async throws -> (GitHubClient, Gist) {
    let github = await client(accountID: account.id)
    let gist = try await github.gist(id: id)
    guard let userID = account.githubUserID, gist.owner?.id == userID else {
      throw DraftError.readOnly
    }
    return (github, gist)
  }

  /// A gist's drafts on this iPhone, which a rename carries along. One that's publishing would
  /// land under the old name.
  private func unsentDrafts(gistID: String, accountID: UUID) async throws -> [GistFileDraft] {
    let local = try await draftStore.drafts(accountID: accountID).filter { $0.gistID == gistID }
    guard !local.contains(where: { $0.sent != nil }) else {
      throw ChangeError.publicationInProgress
    }
    return local
  }
}
