import Foundation
import GistPadSync

enum NotebookAction: Sendable {
  case signOut
  case preference(PreferenceOperation)
  case saveTags([PreferenceOperation])
  case star(gistID: String, starred: Bool)
  case archive(gistID: String, archived: Bool)
  case undoArchive(NotebookArchiveUndo)
  case rename(gistID: String, title: String)
  case renameLocal(draftID: UUID, title: String)
  case renameFile(gistID: String, filename: String, newFilename: String)
  case addFile(gistID: String, filename: String)
  case delete(gistID: String)
  case deleteFile(gistID: String, filename: String)
  case fetchRemote(draftID: UUID)
  case recordRemote(draftID: UUID, generation: UInt64, remote: String?, revision: String?)
  case adoptRemote(draftID: UUID, generation: UInt64, remote: String, revision: String?)
  case discardLocalCopy(draftID: UUID, generation: UInt64)
  case resolveConflict(NotebookReviewContext, text: String, generation: UInt64)
}

enum NotebookActionResult: Sendable {
  case signedOut
  case account(Account)
  case gist(Gist, starred: Bool? = nil)
  case archived(Gist, undo: NotebookArchiveUndo)
  case draft(DraftSnapshot, gist: Gist? = nil)
  case deleted(gistID: String)
  case deletedFile(gistID: String, filename: String, gist: Gist)
  case review(DraftSnapshot)
  case remoteRead(DraftSnapshot, RemoteFile?)
  case discardedDraft(UUID)
}

enum NotebookActionError: Error, Equatable {
  case invalidTitle
  case invalidFilename
  case filenameExists
  case publicationInProgress
  case remoteChangedLocalUpdateFailed(gistID: String)
  case remoteDeletedLocalCleanupFailed(gistID: String)
  case remoteDeletedFileCleanupFailed(gistID: String, filename: String)
  case staleReview
  case archiveChangedElsewhere
}

struct NotebookArchiveUndo: Equatable, Sendable {
  let accountID: UUID
  let gistID: String
  let originalDescription: String
  let archivedDescription: String
  let wasArchived: Bool

  func validate(gist: Gist, accountID: UUID) throws {
    guard self.accountID == accountID else { throw AccountError.accountChanged }
    guard gist.id == gistID,
      (gist.description ?? "").utf8.elementsEqual(archivedDescription.utf8)
    else {
      throw NotebookActionError.archiveChangedElsewhere
    }
  }
}

actor NotebookMutationQueue {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    if busy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      busy = true
    }
    defer {
      if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    try Task.checkCancellation()
    return try await operation()
  }
}

extension LiveNotebookProvider {
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    try await mutationQueue.run { try await self.performSerial(action, accountID: accountID) }
  }

  private func performSerial(
    _ action: NotebookAction, accountID: UUID
  ) async throws -> NotebookActionResult {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    switch action {
    case .preference(let operation):
      return .account(try await accounts.apply([operation], accountID: accountID))
    case .saveTags(let operations):
      return .account(try await accounts.apply(operations, accountID: accountID))
    case .signOut:
      try await accounts.signOut(accountID: accountID)
      return .signedOut
    case .discardLocalCopy(let id, let generation):
      try await drafts.discardLocalCopy(
        id: id, accountID: accountID, expectedGeneration: generation)
      return .discardedDraft(id)
    case .renameLocal(let id, let title):
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NotebookActionError.invalidTitle
      }
      let draft = try await drafts.draft(id: id, accountID: accountID)
      return .draft(
        try await drafts.updateDraftMetadata(
          id: id, accountID: accountID, expectedFilename: draft.filename,
          filename: draft.filename, description: title))
    case .fetchRemote(let id):
      let current = try await drafts.draft(id: id, accountID: accountID)
      guard let gistID = current.gistID else { return .remoteRead(current, nil) }
      let client = await client(accountID: accountID)
      return .remoteRead(
        current,
        try await client.remoteFile(
          gistID: gistID, ownerID: current.githubUserID, filename: current.filename))
    case .recordRemote(let id, let generation, let remote, let revision):
      return .review(
        try await drafts.inspectRemoteChange(
          id: id, accountID: accountID, expectedGeneration: generation,
          remote: remote, revision: revision))
    case .adoptRemote(let id, let generation, let remote, let revision):
      return .review(
        try await drafts.refreshCleanDraft(
          id: id, accountID: accountID, expectedGeneration: generation,
          content: remote, revision: revision))
    case .resolveConflict(let review, let text, let generation):
      guard review.draft.accountID == accountID else { throw AccountError.accountChanged }
      let current = try await drafts.draft(id: review.draft.id, accountID: accountID)
      guard review.matches(current) else { throw NotebookActionError.staleReview }
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
      let updated = try await client.setArchived(archived, gist: gist)
      return .archived(
        updated,
        undo: NotebookArchiveUndo(
          accountID: accountID, gistID: id, originalDescription: gist.description ?? "",
          archivedDescription: updated.description ?? "", wasArchived: gist.isArchived))
    case .undoArchive(let undo):
      let id = undo.gistID
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      try undo.validate(gist: gist, accountID: accountID)
      return .gist(try await client.updateGist(id: id, description: undo.originalDescription))
    case .rename(let id, let title):
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NotebookActionError.invalidTitle
      }
      let local = try await drafts.drafts(accountID: accountID).filter { $0.gistID == id }
      guard !local.contains(where: { $0.attemptedGeneration != nil }) else {
        throw NotebookActionError.publicationInProgress
      }
      let updated = try await client.updateDescription(title, gist: gist)
      do {
        for draft in local {
          _ = try await drafts.updateDraftMetadata(
            id: draft.id, accountID: accountID, expectedFilename: draft.filename,
            filename: draft.filename, description: updated.description ?? "")
        }
      } catch {
        throw NotebookActionError.remoteChangedLocalUpdateFailed(gistID: id)
      }
      return .gist(updated)
    case .renameFile(let id, let filename, let newFilename):
      let (client, gist, _) = try await ownedGist(id: id, account: account)
      try Self.validateFilename(newFilename)
      guard filename != newFilename else { return .gist(gist) }
      guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
      guard gist.files[newFilename] == nil else { throw NotebookActionError.filenameExists }
      let local = try await drafts.drafts(accountID: accountID).filter { $0.gistID == id }
      guard !local.contains(where: { $0.filename == newFilename }) else {
        throw NotebookActionError.filenameExists
      }
      guard !local.contains(where: { $0.attemptedGeneration != nil }) else {
        throw NotebookActionError.publicationInProgress
      }
      let updated = try await client.updateGist(id: id, files: [filename: .rename(newFilename)])
      do {
        for draft in local where draft.filename == filename {
          _ = try await drafts.updateDraftMetadata(
            id: draft.id, accountID: accountID, expectedFilename: filename,
            filename: newFilename, description: updated.description ?? "")
        }
      } catch {
        throw NotebookActionError.remoteChangedLocalUpdateFailed(gistID: id)
      }
      return .gist(updated)
    case .addFile(let id, let filename):
      let (_, gist, userID) = try await ownedGist(id: id, account: account)
      try Self.validateFilename(filename)
      guard gist.files[filename] == nil else { throw NotebookActionError.filenameExists }
      let draft = try await drafts.openDraft(
        accountID: accountID, githubUserID: userID, gistID: id, filename: filename,
        description: gist.description ?? "", content: "", isNewFile: true)
      return .draft(draft, gist: gist)
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
      // A retry after a partial failure finds the file already gone, so only local cleanup remains.
      let updated: Gist
      if gist.files[filename] == nil {
        updated = gist
      } else {
        updated = try await client.updateGist(id: id, files: [filename: .delete])
      }
      do {
        try await drafts.removeDrafts(
          gistID: id, filename: filename, updated: updated, accountID: accountID)
        return .deletedFile(gistID: id, filename: filename, gist: updated)
      } catch {
        throw NotebookActionError.remoteDeletedFileCleanupFailed(gistID: id, filename: filename)
      }
    }
  }

  private func deleteGist(
    _ id: String, client: GitHubClient, accountID: UUID
  ) async throws -> NotebookActionResult {
    try await client.deleteGist(id: id)
    do {
      try await CommentConversationDiskStore.applicationStore().removeDrafts(
        scope: .init(accountID: accountID, gistID: id))
      try await drafts.removeDrafts(gistID: id, accountID: accountID)
      return .deleted(gistID: id)
    } catch {
      throw NotebookActionError.remoteDeletedLocalCleanupFailed(gistID: id)
    }
  }

  private func ownedGist(
    id: String, account: Account
  ) async throws -> (GitHubClient, Gist, Int64) {
    let client = await client(accountID: account.id)
    let gist = try await client.gist(id: id)
    let userID: Int64
    if let cached = account.githubUserID {
      userID = cached
    } else {
      userID = try await client.authenticatedUser().id
    }
    guard gist.owner?.id == userID else { throw DraftError.readOnly }
    return (client, gist, userID)
  }

  private static func validateFilename(_ filename: String) throws {
    guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      filename.hasSuffix(".md"), !filename.contains("/"), !filename.contains("\0")
    else { throw NotebookActionError.invalidFilename }
  }
}

struct NotebookReviewContext: Equatable, Sendable, Identifiable {
  var id: UUID { draft.id }
  let draft: DraftSnapshot
  let conflict: DraftConflict

  static func == (left: Self, right: Self) -> Bool { left.matches(right.draft) }

  init(draft: DraftSnapshot) throws {
    guard case .conflict(let conflict) = draft.state, conflict.generation == draft.generation else {
      throw NotebookActionError.staleReview
    }
    self.draft = draft
    self.conflict = conflict
  }

  func matches(_ current: DraftSnapshot) -> Bool {
    guard current.id == draft.id, current.accountID == draft.accountID,
      current.gistID == draft.gistID, current.filename.utf8.elementsEqual(draft.filename.utf8),
      current.generation == draft.generation, case .conflict(let conflict) = current.state
    else {
      return false
    }
    return conflict.generation == self.conflict.generation
      && conflict.remoteRevision == self.conflict.remoteRevision
      && Self.exactlyEqual(conflict.base, self.conflict.base)
      && Self.exactlyEqual(conflict.local, self.conflict.local)
      && Self.exactlyEqual(conflict.remote, self.conflict.remote)
  }

  static func exactlyEqual(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (.none, .none): true
    case (.some(let left), .some(let right)): left.utf8.elementsEqual(right.utf8)
    default: false
    }
  }
}
