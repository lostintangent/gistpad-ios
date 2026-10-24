import Foundation
import GistPadSync

enum NotebookAction: Sendable {
  case preference(PreferenceOperation)
  case star(gistID: String, starred: Bool)
  case archive(gistID: String, archived: Bool)
  case rename(gistID: String, title: String)
  case renameLocal(draftID: UUID, title: String)
  case renameFile(gistID: String, filename: String, newFilename: String)
  case addFile(gistID: String, filename: String)
  case delete(gistID: String)
  case refreshConflict(NotebookReviewContext)
  case resolveConflict(NotebookReviewContext, text: String, generation: UInt64)
}

enum NotebookActionResult: Sendable {
  case account(NotebookAccount)
  case gist(Gist, starred: Bool? = nil)
  case draft(DraftSnapshot, gist: Gist? = nil)
  case deleted(gistID: String, drafts: DeletedGistDrafts)
  case review(DraftSnapshot)
}

enum NotebookActionError: Error, Equatable {
  case invalidTitle
  case invalidFilename
  case filenameExists
  case publicationInProgress
  case remoteChangedLocalUpdateFailed(gistID: String)
  case remoteDeletedLocalCleanupFailed(gistID: String)
  case staleReview
  case remoteReviewChanged
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
    if case .preference(let operation) = action {
      return .account(NotebookAccount(try await accounts.apply(operation, accountID: accountID)))
    }
    if case .renameLocal(let id, let title) = action {
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NotebookActionError.invalidTitle
      }
      let draft = try await drafts.draft(id: id, accountID: accountID)
      return .draft(
        try await drafts.updateDraftMetadata(
          id: id, accountID: accountID, expectedFilename: draft.filename,
          filename: draft.filename, description: title))
    }
    let client = await accounts.githubClient(accountID: accountID)
    switch action {
    case .refreshConflict(let review), .resolveConflict(let review, _, _):
      guard review.draft.accountID == accountID, let gistID = review.draft.gistID else {
        throw AccountError.accountChanged
      }
      let current = try await drafts.draft(id: review.draft.id, accountID: accountID)
      guard review.matches(current) else { throw NotebookActionError.staleReview }
      let gist = try await client.gist(id: gistID)
      guard gist.owner?.id == current.githubUserID else { throw DraftError.readOnly }
      guard gist.truncated != true else { throw GitHubClientError.incompleteGist }
      let remote: String?
      if gist.files[current.filename] != nil {
        remote = try await client.content(gist: gist, filename: current.filename)
      } else {
        remote = nil
      }
      if case .resolveConflict(_, let text, let generation) = action {
        guard review.conflict.remoteRevision == gist.revision,
          NotebookReviewContext.exactlyEqual(review.conflict.remote, remote)
        else {
          throw NotebookActionError.remoteReviewChanged
        }
        return .review(
          try await drafts.resolveConflict(
            id: current.id, accountID: accountID, expectedGeneration: current.generation,
            text: text, generation: generation))
      }
      return .review(
        try await drafts.refreshConflict(
          id: current.id, accountID: accountID, expectedGeneration: current.generation,
          expectedConflict: review.conflict, remote: remote, revision: gist.revision))
    default:
      break
    }
    if case .star(let id, let starred) = action {
      let gist = try await client.gist(id: id)
      try await client.setStarred(starred, id: id)
      return .gist(gist, starred: starred)
    }
    let id: String
    switch action {
    case .archive(let gistID, _), .rename(let gistID, _),
      .renameFile(let gistID, _, _), .addFile(let gistID, _), .delete(let gistID):
      id = gistID
    case .star, .preference, .renameLocal, .refreshConflict, .resolveConflict:
      preconditionFailure("Handled before the owner-only action boundary.")
    }
    let gist = try await client.gist(id: id)
    let userID: Int64
    if let cached = account.githubUserID {
      userID = cached
    } else {
      userID = try await client.authenticatedUser().id
    }
    guard gist.owner?.id == userID else { throw DraftError.readOnly }
    switch action {
    case .archive(_, let archived):
      return .gist(try await client.setArchived(archived, gist: gist))
    case .rename(_, let title):
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
    case .renameFile(_, let filename, let newFilename):
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
    case .addFile(_, let filename):
      try Self.validateFilename(filename)
      guard gist.files[filename] == nil else { throw NotebookActionError.filenameExists }
      let draft = try await drafts.newFileDraft(
        accountID: accountID, githubUserID: userID, gistID: id, filename: filename,
        description: gist.description ?? "", text: "")
      return .draft(draft, gist: gist)
    case .delete:
      try await client.deleteGist(id: id)
      do {
        return .deleted(
          gistID: id,
          drafts: try await drafts.removeCleanDraftsForDeletedGist(gistID: id, accountID: accountID)
        )
      } catch {
        throw NotebookActionError.remoteDeletedLocalCleanupFailed(gistID: id)
      }
    case .star, .preference, .renameLocal, .refreshConflict, .resolveConflict:
      preconditionFailure("Handled before the owner-only action boundary.")
    }

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
      && Self.exactlyEqual(conflict.suggestedMerge, self.conflict.suggestedMerge)
  }

  static func exactlyEqual(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (.none, .none): true
    case (.some(let left), .some(let right)): left.utf8.elementsEqual(right.utf8)
    default: false
    }
  }
}
