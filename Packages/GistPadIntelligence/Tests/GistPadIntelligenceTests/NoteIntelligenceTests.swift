import Foundation
import Testing

@testable import GistPadIntelligence

struct NoteAnchorTests {
  @Test func anEmptyNoteHasExactlyOneSafeInsertionAnchor() throws {
    let snapshot = note("")
    let proposal = NoteProposal(snapshot: snapshot, candidates: [change("", "A new paragraph")])
    #expect(proposal.canApply)
    #expect(try proposal.application(to: snapshot).source == "A new paragraph")
    #expect(NoteAnchors.matches("", in: "").isEmpty)
    let overlapping = NoteProposal(
      snapshot: snapshot, candidates: [change("", "First"), change("", "Second")])
    #expect(overlapping.omittedCount == 2)
    #expect(!overlapping.canApply)
  }

  @Test func literalAnchorsRejectMissingAmbiguousAndNormalizedQuotes() {
    let snapshot = note("same same cafe\u{301}")
    let proposal = NoteProposal(
      snapshot: snapshot,
      candidates: [
        change("same", "different"),
        change("absent", "present"),
        change("café", "coffee"),
      ])
    #expect(proposal.omittedCount == 3)
    #expect(proposal.comments.map(\.rejection) == [.ambiguous, .notFound, .notFound])
    #expect(!proposal.canApply)
  }

  @Test func exactContextDisambiguatesRepeatedTextWithoutTrustingOffsets() throws {
    let snapshot = note("left same\nright same")
    let proposal = NoteProposal(
      snapshot: snapshot,
      candidates: [
        NoteReplacementCandidate(
          quote: "same", replacement: "different", reason: "Clarify", before: "right ")
      ])
    #expect(proposal.omittedCount == 0)
    let result = try proposal.application(to: snapshot)
    #expect(result.source == "left same\nright different")
  }

  @Test func everyParticipantInAnOverlapIsRejected() throws {
    let snapshot = note("abcdef safe")
    let proposal = NoteProposal(
      snapshot: snapshot,
      candidates: [change("abcd", "one"), change("cdef", "two"), change("safe", "kept")])
    #expect(proposal.omittedCount == 2)
    #expect(proposal.comments.prefix(2).allSatisfy { $0.rejection == .overlapping })
    #expect(try proposal.application(to: snapshot).source == "abcdef kept")
  }

  @Test func unicodeCRLFAndDeletionProduceAnAppComputedLosslessDiff() throws {
    let snapshot = note("👩🏽‍💻 bad\r\nSecond line\r\n")
    let proposal = NoteProposal(
      snapshot: snapshot,
      candidates: [change("bad", "good"), change("Second line\r\n", "")])
    let application = try proposal.application(to: snapshot)
    #expect(application.source == "👩🏽‍💻 good\r\n")
    #expect(application.diff.filter { $0.kind == .removed }.map(\.text).joined() == snapshot.source)
    #expect(
      application.diff.filter { $0.kind == .added }.map(\.text).joined() == application.source)
    let selection = NSRange(location: snapshot.source.utf16.count, length: 0)
    #expect(
      try application.mappedSelection(selection)
        == NSRange(location: application.source.utf16.count, length: 0))
  }

  @Test func staleGenerationDocumentSessionAndBytesAreAllRejected() throws {
    let snapshot = note("cafe\u{301}")
    let proposal = NoteProposal(snapshot: snapshot, candidates: [change(snapshot.source, "coffee")])
    let alternatives = [
      NoteSnapshot(
        documentID: snapshot.documentID, sessionID: snapshot.sessionID,
        generation: 1, source: snapshot.source),
      NoteSnapshot(
        documentID: "another", sessionID: snapshot.sessionID,
        generation: 0, source: snapshot.source),
      NoteSnapshot(
        documentID: snapshot.documentID, sessionID: UUID(),
        generation: 0, source: snapshot.source),
      NoteSnapshot(
        documentID: snapshot.documentID, sessionID: snapshot.sessionID,
        generation: 0, source: "café"),
    ]
    for alternative in alternatives {
      #expect(throws: NoteIntelligenceError.self) { try proposal.application(to: alternative) }
    }
  }

  @Test func individualReviewApplicationsRebaseRemainingAnchorsWithoutAModel() throws {
    let snapshot = note("first bad and second typo")
    let proposal = NoteProposal(
      snapshot: snapshot, candidates: [change("bad", "much better"), change("typo", "word")])
    let first = try proposal.application(to: snapshot, commentID: proposal.comments[0].id)
    let updated = NoteSnapshot(
      documentID: snapshot.documentID, sessionID: snapshot.sessionID,
      generation: 1, source: first.source)
    let remaining = try first.remainingReview(on: updated)
    #expect(remaining.comments.count == 1)
    #expect(remaining.comments[0].id == proposal.comments[1].id)
    #expect(remaining.comments[0].canApply)
    #expect(try remaining.application(to: updated).source == "first much better and second word")
    #expect(throws: NoteIntelligenceError.self) { try proposal.application(to: updated) }
  }

  @Test func commentOnlyAndNoOpSuggestionsNeverOfferApply() {
    let snapshot = note("Clear text")
    let proposal = NoteProposal(
      snapshot: snapshot,
      candidates: [
        NoteReplacementCandidate(quote: "Clear", replacement: nil, reason: "A comment"),
        change("text", "text"),
      ])
    #expect(proposal.comments.allSatisfy { $0.range != nil })
    #expect(proposal.omittedCount == 0)
    #expect(!proposal.canApply)
    #expect(throws: NoteIntelligenceError.self) { try proposal.application(to: snapshot) }
  }
}

@MainActor
struct NoteEngineTests {
  @Test func aNoteExactlyAtTheMeasuredBudgetUsesOnePassAndOneMoreUnitSplits() async throws {
    let backend = FakeNoteModel()
    let engine = NoteIntelligenceEngine(backend: backend)
    let capacity = backend.context - backend.context / 3 - 96 - backend.overhead - 1
    let first = note(String(repeating: "a", count: capacity))
    _ = try await engine.propose(
      NoteIntelligenceRequest(snapshot: first, action: .edit, instruction: "x"))
    #expect(backend.replacementPasses.count == 1)
    backend.replacementPasses = []
    let larger = note(first.source + "a")
    _ = try await engine.propose(
      NoteIntelligenceRequest(snapshot: larger, action: .edit, instruction: "x"))
    #expect(backend.replacementPasses.count == 2)
    #expect(backend.replacementPasses.map(\.source).joined() == larger.source)
  }

  @Test func longNotesCoverEveryByteAndMergeChangesAgainstTheirOwnPass() async throws {
    let source = String(repeating: "# Section\nbad 👩🏽‍💻\r\n", count: 180)
    let snapshot = note(source)
    let backend = FakeNoteModel()
    let proposal = try await NoteIntelligenceEngine(backend: backend).propose(
      NoteIntelligenceRequest(snapshot: snapshot, action: .edit, instruction: "Fix bad"))
    #expect(backend.replacementPasses.count > 1)
    #expect(backend.replacementPasses.map(\.source).joined().utf8.elementsEqual(source.utf8))
    #expect(proposal.omittedCount == 0)
    #expect(
      try proposal.application(to: snapshot).source
        == source.replacingOccurrences(of: "bad", with: "good"))
  }

  @Test func oversizedGeneratedChangesRetrySmallerPassesRatherThanAcceptPartialOutput() async throws
  {
    let backend = FakeNoteModel()
    backend.maximumGeneratedSourceLength = 100
    let snapshot = note(String(repeating: "bad ", count: 100))
    let proposal = try await NoteIntelligenceEngine(backend: backend).propose(
      NoteIntelligenceRequest(snapshot: snapshot, action: .edit, instruction: "Fix bad"))
    #expect(backend.replacementPasses.contains { $0.source.count > 100 })
    #expect(
      try proposal.application(to: snapshot).source
        == snapshot.source.replacingOccurrences(of: "bad", with: "good"))
  }

  @Test func sourceQuotationsAreVerifiedBeforeTheyReachTheStream() async throws {
    let backend = FakeNoteModel()
    backend.answerParts = [
      ModelAnswerPart(kind: .prose, text: "The note says:"),
      ModelAnswerPart(kind: .quote, text: "fabricated"),
    ]
    var emitted: [NoteAnswerPart] = []
    await #expect(throws: NoteIntelligenceError.self) {
      try await NoteIntelligenceEngine(backend: backend).ask(
        NoteIntelligenceRequest(
          snapshot: note("Real source"), action: .ask, instruction: "Quote it"),
        onUpdate: { emitted = $0 })
    }
    #expect(emitted == [.prose("The note says:")])
  }

  @Test func validQuotedUnicodeCarriesTheExactUTF16SourceRange() async throws {
    let backend = FakeNoteModel()
    backend.answerParts = [ModelAnswerPart(kind: .quote, text: "👩🏽‍💻")]
    let snapshot = note("Hello 👩🏽‍💻\r\n")
    let answer = try await NoteIntelligenceEngine(backend: backend).ask(
      NoteIntelligenceRequest(snapshot: snapshot, action: .ask, instruction: "Quote the emoji"))
    guard case .quotation(let citation) = try #require(answer.parts.first) else {
      Issue.record("Expected a verified quotation")
      return
    }
    #expect(citation.ranges == [NSRange(location: 6, length: "👩🏽‍💻".utf16.count)])
    #expect(answer.snapshot == snapshot)
  }

  @Test func longAskScansTheEntireNoteBeforeAnsweringFromVerifiedEvidence() async throws {
    let backend = FakeNoteModel()
    backend.excerpt = "needle"
    backend.answerParts = [ModelAnswerPart(kind: .quote, text: "needle")]
    let source = String(repeating: "A background paragraph.\n\n", count: 100) + "needle"
    let snapshot = note(source)
    let answer = try await NoteIntelligenceEngine(backend: backend).ask(
      NoteIntelligenceRequest(snapshot: snapshot, action: .ask, instruction: "Find needle"))
    #expect(backend.extractionPasses.map(\.source).joined().utf8.elementsEqual(source.utf8))
    #expect(backend.answerPasses.count == 1)
    #expect(backend.answerPasses[0].source == "needle")
    #expect(backend.answerPasses[0].evidenceOnly)
    #expect(answer.parts.count == 1)
  }

  @Test func cancellationAndUnavailabilityNeverReachGeneration() async {
    let backend = FakeNoteModel()
    let request = NoteIntelligenceRequest(snapshot: note("bad"), action: .edit, instruction: "Fix")
    let task = Task { try await NoteIntelligenceEngine(backend: backend).propose(request) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(backend.replacementPasses.isEmpty)
    backend.available = false
    await #expect(throws: NoteIntelligenceError.self) {
      try await NoteIntelligenceEngine(backend: backend).propose(request)
    }

    #expect(backend.replacementPasses.isEmpty)
  }

  @Test func editRejectsACommentInsteadOfAReplacement() async {
    let backend = FakeNoteModel()
    backend.omitReplacement = true
    await #expect(throws: NoteIntelligenceError.self) {
      try await NoteIntelligenceEngine(backend: backend).propose(
        NoteIntelligenceRequest(snapshot: note("bad"), action: .edit, instruction: "Fix"))
    }
  }
}

@MainActor
private final class FakeNoteModel: NoteModelBackend {
  let context = 1_536
  let overhead = 64
  var available = true
  var omitReplacement = false
  var maximumGeneratedSourceLength = Int.max
  var replacementPasses: [NoteModelPass] = []
  var extractionPasses: [NoteModelPass] = []
  var answerPasses: [NoteModelPass] = []
  var answerParts = [ModelAnswerPart(kind: .prose, text: "An answer")]
  var excerpt = ""

  func modelInfo() async throws -> NoteModelInfo {
    guard available else { throw NoteIntelligenceError.unavailable("Model not ready") }
    return NoteModelInfo(variant: "Fake", contextSize: context)
  }

  func tokenCount(for pass: NoteModelPass) async throws -> Int {
    overhead + pass.source.utf16.count + pass.instruction.utf16.count
  }

  func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
    replacementPasses.append(pass)
    guard pass.source.count <= maximumGeneratedSourceLength else {
      throw NoteIntelligenceError.responseTooLarge
    }
    return [
      NoteReplacementCandidate(
        quote: pass.source,
        replacement: omitReplacement
          ? nil : pass.source.replacingOccurrences(of: "bad", with: "good"),
        reason: "Fix")
    ]
  }

  func excerpts(for pass: NoteModelPass) async throws -> [String] {
    extractionPasses.append(pass)
    return !excerpt.isEmpty && pass.source.contains(excerpt) ? [excerpt] : []
  }

  func answer(
    for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
  ) async throws -> [ModelAnswerPart] {
    answerPasses.append(pass)
    onUpdate(answerParts)
    return answerParts
  }
}

private func note(_ source: String) -> NoteSnapshot {
  NoteSnapshot(documentID: "note.md", sessionID: UUID(), generation: 0, source: source)
}

private func change(_ quote: String, _ replacement: String) -> NoteReplacementCandidate {
  NoteReplacementCandidate(quote: quote, replacement: replacement, reason: "Improve")
}
