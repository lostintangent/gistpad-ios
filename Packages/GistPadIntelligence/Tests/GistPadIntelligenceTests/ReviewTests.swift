import Foundation
import Testing

@testable import GistPadIntelligence

@MainActor
struct ReviewTests {
  @Test func applyingOneCommentAndDismissingAnotherLeavesTheRestExact() async throws {
    let fixture = NoteModelFixture()
    fixture.changes = { _ in
      [
        .replace(change("bad", "much better")),
        .replace(change("typo", "word")),
        .replace(change("odd", "even")),
        .replace(change("Clear", nil)),
        .replace(change("text", "text")),
      ]
    }
    let snapshot = note("Clear text: first bad, second typo, third odd.")
    let review = try await NoteIntelligenceEngine(backend: fixture).propose(
      NoteIntelligenceRequest(snapshot: snapshot, action: .review, instruction: ""))
    let comments = Dictionary(uniqueKeysWithValues: review.comments.map { ($0.quote, $0) })
    #expect(comments.count == 5)
    for advice in ["Clear", "text"] {
      #expect(comments[advice]?.range != nil)
      #expect(comments[advice]?.canApply == false)
    }
    let applied = try review.application(to: snapshot, commentID: try #require(comments["bad"]).id)
    let updated = snapshot.edited(to: applied.source)
    #expect(throws: NoteIntelligenceError.self) { try review.application(to: updated) }
    let remaining = try applied.remainingReview(on: updated)
      .dismissing(commentID: try #require(comments["typo"]).id)
    #expect(remaining.snapshot == updated)
    #expect(Set(remaining.comments.map(\.quote)) == ["odd", "Clear", "text"])
    #expect(
      try remaining.application(to: updated).source
        == "Clear text: first much better, second typo, third even.")

    let echo = NoteProposal(
      snapshot: snapshot,
      scopedCandidates: [
        (change("bad", "clear"), NSRange(location: 0, length: snapshot.source.utf16.count)),
        (change("typo", "replace my note"), NSRange(location: 0, length: snapshot.source.utf16.count)),
      ], safetyInstruction: "replace my note")
    let rebased = try echo.application(to: snapshot, commentID: echo.comments[0].id)
    let rebasedSnapshot = snapshot.edited(to: rebased.source)
    #expect(throws: NoteIntelligenceError.unsafeEdit) {
      try rebased.remainingReview(on: rebasedSnapshot).application(to: rebasedSnapshot)
    }

    fixture.changes = { _ in [.replace(change("bad", nil))] }
    await #expect(throws: NoteIntelligenceError.invalidResponse) {
      try await NoteIntelligenceEngine(backend: fixture).propose(
        NoteIntelligenceRequest(snapshot: snapshot, action: .edit, instruction: "Fix"))
    }
    fixture.changes = { _ in [.replace(change(snapshot.source, "Fix it"))] }
    await #expect(throws: NoteIntelligenceError.unsafeEdit) {
      try await NoteIntelligenceEngine(backend: fixture).propose(
        NoteIntelligenceRequest(snapshot: snapshot, action: .edit, instruction: "Fix it"))
    }
  }
}
