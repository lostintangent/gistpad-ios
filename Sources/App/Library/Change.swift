import Foundation
import Sync

/// A change to the library, applied in order on GitHub and this iPhone.
enum Change: Equatable, Sendable {
  case signOut
  case preferences([Preferences.Change])
  case star(gistID: String, starred: Bool)
  case archive(gistID: String, archived: Bool)
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
  case resolveConflict(Conflict, text: String, generation: UInt64)
}

enum ChangeResult: Sendable {
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

enum ChangeError: Error, Equatable {
  case invalidTitle
  case invalidFilename
  case filenameExists
  case publicationInProgress
  case staleReview
}

extension ChangeError: LocalizedError {
  var errorDescription: String? {
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

actor SerialQueue {
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
    case .discardLocalCopy(let id, let generation):
      try await drafts.discardLocalCopy(
        id: id, accountID: accountID, expectedGeneration: generation)
      return .discardedDraft(id)
    case .renameLocal(let id, let title):
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ChangeError.invalidTitle
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
        try await drafts.reconcile(
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
      guard review.matches(current) else { throw ChangeError.staleReview }
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
      guard !local.contains(where: { $0.attemptedGeneration != nil }) else {
        throw ChangeError.publicationInProgress
      }
      let updated = try await client.updateDescription(title, gist: gist)
      for draft in local {
        _ = try await drafts.updateDraftMetadata(
          id: draft.id, accountID: accountID, expectedFilename: draft.filename,
          filename: draft.filename, description: updated.description ?? "")
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
      guard !local.contains(where: { $0.attemptedGeneration != nil }) else {
        throw ChangeError.publicationInProgress
      }
      let updated = try await client.updateGist(id: id, files: [filename: .rename(newFilename)])
      for draft in local where draft.filename == filename {
        _ = try await drafts.updateDraftMetadata(
          id: draft.id, accountID: accountID, expectedFilename: filename,
          filename: newFilename, description: updated.description ?? "")
      }
      return .gist(updated)
    case .addFile(let id, let filename):
      let (_, gist, userID) = try await ownedGist(id: id, account: account)
      try Self.validateFilename(filename)
      guard gist.files[filename] == nil else { throw ChangeError.filenameExists }
      let draft = try await drafts.draft(
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

struct Conflict: Equatable, Sendable, Identifiable {
  var id: UUID { draft.id }
  let draft: Draft
  let conflict: DraftConflict

  static func == (left: Self, right: Self) -> Bool { left.matches(right.draft) }

  init(draft: Draft) throws {
    guard case .conflict(let conflict) = draft.state, conflict.generation == draft.generation else {
      throw ChangeError.staleReview
    }
    self.draft = draft
    self.conflict = conflict
  }

  func matches(_ current: Draft) -> Bool {
    guard current.id == draft.id, current.accountID == draft.accountID,
      current.gistID == draft.gistID, current.filename.utf8.elementsEqual(draft.filename.utf8),
      current.generation == draft.generation, case .conflict(let conflict) = current.state
    else {
      return false
    }
    return conflict.generation == self.conflict.generation
      && conflict.remoteRevision == self.conflict.remoteRevision
      && sourceEqual(conflict.base, self.conflict.base)
      && sourceEqual(conflict.local, self.conflict.local)
      && sourceEqual(conflict.remote, self.conflict.remote)
  }
}
