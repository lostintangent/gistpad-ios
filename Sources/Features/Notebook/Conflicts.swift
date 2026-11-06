import Editor
import Foundation
import Sync

// When GitHub changed a note you also edited, you see both versions and choose what to keep.

public struct Conflict: Equatable, Sendable, Identifiable {
  public var id: UUID { draft.id }
  public let draft: Draft
  public let conflict: DraftConflict

  public static func == (left: Self, right: Self) -> Bool { left.matches(right.draft) }

  init(draft: Draft) throws {
    guard case .conflict(let conflict) = draft.state, conflict.generation == draft.generation else {
      throw ChangeError.staleReview
    }
    self.draft = draft
    self.conflict = conflict
  }

  public func matches(_ current: Draft) -> Bool {
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

extension FileSession {
  public func reviewContext() throws -> Conflict {
    let review = try Conflict(draft: draft)
    guard editor.generation == draft.generation,
      editor.text.utf8.elementsEqual(draft.text.utf8)
    else { throw ChangeError.staleReview }
    return review
  }

  public func applyReview(_ review: Conflict, text: String, publishes: Bool) async throws {
    guard review.matches(draft), editor.generation == review.draft.generation else {
      throw ChangeError.staleReview
    }
    let changed = !text.utf8.elementsEqual(editor.text.utf8)
    let generation = editor.generation + (changed ? 1 : 0)
    try await commitMutation(
      Edit(
        range: NSRange(location: 0, length: editor.text.utf16.count),
        expected: editor.text, replacement: text),
      expectedGeneration: review.draft.generation
    ) {
      guard
        case .review(let resolved) = try await library.perform(
          .resolveConflict(review, text: text, generation: generation))
      else {
        throw ChangeError.staleReview
      }
      return resolved
    }
    if publishes { await publish() }
  }
}
