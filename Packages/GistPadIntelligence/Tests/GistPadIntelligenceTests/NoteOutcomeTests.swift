import Foundation
import Testing

@testable import GistPadIntelligence

@MainActor
struct NoteOutcomeTests {
  private let manga = """
    # Manga Reading List

    ### Currently reading
    1. Frieren, volume 8
    2. Witch Hat Atelier, volume 4

    ### Next
    1. Yotsuba&!, volume 1
    2. A short series for the weekend
    """

  @Test(arguments: [
    [], [ModelAnswerPart(kind: .prose, text: " \n\t")],
    [ModelAnswerPart(kind: .quote, text: "\n")],
  ])
  func emptyMangaAnswersFailVisibly(parts: [ModelAnswerPart]) async {
    let backend = OutcomeModel()
    backend.parts = parts
    var emitted: [NoteAnswerPart] = []
    await #expect(throws: NoteIntelligenceError.emptyAnswer) {
      try await NoteIntelligenceEngine(backend: backend).ask(
        request(manga, action: .ask, instruction: "What's the summary of the manga reading list?"),
        onUpdate: { emitted = $0 })
    }
    #expect(emitted.isEmpty)
  }

  @Test func mangaSummaryKeepsTheWholeStructuredNoteAndRequestIdentity() async throws {
    let backend = OutcomeModel()
    backend.parts = [
      ModelAnswerPart(kind: .prose, text: "You are reading two series and have two next reads."),
      ModelAnswerPart(kind: .quote, text: "1. Frieren, volume 8"),
    ]
    let input = request(manga, action: .ask, instruction: "Summarize my reading list")
    let answer = try await NoteIntelligenceEngine(backend: backend).ask(input)
    #expect(answer.parts.count == 2)
    #expect(backend.lastPass?.source == manga)
    #expect(backend.lastPass?.requestID == input.id)
    #expect(answer.snapshot.source.utf8.elementsEqual(manga.utf8))
  }

  @Test func longMangaWithoutVerifiedEvidenceExplainsWhyItCannotAnswer() async {
    let backend = OutcomeModel()
    backend.contextSize = 512
    await #expect(throws: NoteIntelligenceError.noEvidence) {
      try await NoteIntelligenceEngine(backend: backend).ask(
        request(
          String(repeating: manga + "\n\n", count: 20), action: .ask,
          instruction: "Summarize my reading list"))
    }
    #expect(backend.lastPass == nil)
  }

  @Test(arguments: ["mark everything complete", "check off everything", "すべて完了にして"])
  func structuredTaskOperationChangesOnlyTodaysEmptyMarker(instruction: String) async throws {
    let source = "## 📆 2026-10-24\n\n- [ ]"
    let backend = OutcomeModel()
    backend.operations = [.setTaskStates(ids: nil, isComplete: true)]
    let input = request(source, instruction: instruction, tasks: [task(1, "[ ]", in: source)])
    let proposal = try await NoteIntelligenceEngine(backend: backend).propose(input)
    #expect(backend.lastPass?.instruction == instruction)
    #expect(backend.lastPass?.tasks.count == 1)
    #expect(proposal.comments.count == 1)
    #expect(try proposal.application(to: input.snapshot).source == "## 📆 2026-10-24\n\n- [x]")
  }

  @Test func subsetAndUncheckOperationsUseStableIDsNotInstructionMatching() async throws {
    let source = "# Today 👩🏽‍💻\r\n\r\n- [ ] Read café\r\n- [X] Done\r\n- [ ] Keep this\r\n"
    let tasks = [
      task(1, "[ ]", in: source), task(2, "[X]", in: source),
      task(3, "[ ]", in: source, backwards: true),
    ]
    let backend = OutcomeModel()
    backend.operations = [.setTaskStates(ids: [1, 2], isComplete: true)]
    let input = request(source, instruction: "mark the first two done", tasks: tasks)
    let proposal = try await NoteIntelligenceEngine(backend: backend).propose(input)
    #expect(proposal.comments.count == 1)
    #expect(
      try proposal.application(to: input.snapshot).source
        == "# Today 👩🏽‍💻\r\n\r\n- [x] Read café\r\n- [X] Done\r\n- [ ] Keep this\r\n")
    backend.operations = [.setTaskStates(ids: nil, isComplete: false)]
    let uncheckRequest = request(source, instruction: "uncheck all", tasks: tasks)
    let uncheck = try await NoteIntelligenceEngine(backend: backend).propose(uncheckRequest)
    #expect(
      try uncheck.application(to: uncheckRequest.snapshot).source
        == source.replacingOccurrences(of: "[X]", with: "[ ]"))
  }

  @Test(arguments: [[99], [1, 1], []])
  func invalidTaskIDsAreRejected(ids: [Int]) async {
    let source = "- [ ] Keep the note"
    let backend = OutcomeModel()
    backend.operations = [.setTaskStates(ids: ids, isComplete: true)]
    await #expect(throws: NoteIntelligenceError.invalidResponse) {
      try await NoteIntelligenceEngine(backend: backend).propose(
        request(source, instruction: "Complete it", tasks: [task(1, "[ ]", in: source)]))
    }
  }

  @Test(arguments: [
    "mark everything complete", " \n MARK   EVERYTHING COMPLETE \t",
    "\"mark everything complete!\"", "", "Done",
  ])
  func dailyNoteEchoAndNearEmptyWipesNeverBecomeApplicable(replacement: String) async {
    let source = "## 📆 2026-10-24\n\n- [ ]"
    let backend = OutcomeModel()
    backend.operations = [
      .replace(
        NoteReplacementCandidate(quote: source, replacement: replacement, reason: "Complete tasks"))
    ]
    await #expect(throws: NoteIntelligenceError.unsafeEdit) {
      try await NoteIntelligenceEngine(backend: backend).propose(
        request(source, instruction: "mark everything complete"))
    }
  }

  @Test func meaningfulLargeShorteningIsNotBlockedByARetentionThreshold() async throws {
    let source = String(repeating: "A detailed background paragraph with examples.\n\n", count: 30)
    let summary = "The team agreed to ship a focused, on-device notebook."
    let backend = OutcomeModel()
    backend.operations = [
      .replace(
        NoteReplacementCandidate(quote: source, replacement: summary, reason: "Shorten the note"))
    ]
    let input = request(source, instruction: "shorten this")
    let proposal = try await NoteIntelligenceEngine(backend: backend).propose(input)
    #expect(try proposal.application(to: input.snapshot).source == summary)
  }

  @Test func wholeNoteTaskOperationsCoverEveryChunkWithoutSplittingAMarker() async throws {
    let source = (1...80).map { "- [ ] Task \($0) 👩🏽‍💻\r\n" }.joined()
    let tasks = NoteAnchors.matches("[ ]", in: source).enumerated().map {
      NoteTask(
        id: $0.offset + 1, range: $0.element, text: "Task \($0.offset + 1)", isComplete: false)
    }
    let backend = OutcomeModel()
    backend.contextSize = 512
    backend.operations = [.setTaskStates(ids: nil, isComplete: true)]
    let input = request(source, instruction: "Check off everything", tasks: tasks)
    let proposal = try await NoteIntelligenceEngine(backend: backend).propose(input)
    #expect(backend.editPasses.count > 1)
    #expect(backend.editPasses.flatMap(\.tasks).map(\.id) == Array(1...80))
    #expect(proposal.omittedCount == 0)
    #expect(proposal.comments.count == 80)
    #expect(
      try proposal.application(to: input.snapshot).source.utf8.elementsEqual(
        source.replacingOccurrences(of: "[ ]", with: "[x]").utf8))
  }

  @Test func applySafetyIsRetainedAfterIndividualReviewRebasing() throws {
    let input = request("A bad paragraph and typo.", instruction: "replace my note")
    let proposal = NoteProposal(
      snapshot: input.snapshot,
      scopedCandidates: [
        (
          NoteReplacementCandidate(quote: "bad", replacement: "clear", reason: "Clarity"),
          NSRange(location: 0, length: input.snapshot.source.utf16.count)
        ),
        (
          NoteReplacementCandidate(quote: "typo", replacement: "replace my note", reason: "Unsafe"),
          NSRange(location: 0, length: input.snapshot.source.utf16.count)
        ),
      ], safetyInstruction: input.instruction)
    let first = try proposal.application(
      to: input.snapshot, commentID: proposal.comments[0].id)
    let updated = NoteSnapshot(
      documentID: input.snapshot.documentID, sessionID: input.snapshot.sessionID,
      generation: 1, source: first.source)
    let remaining = try first.remainingReview(on: updated)
    #expect(throws: NoteIntelligenceError.unsafeEdit) {
      try remaining.application(to: updated)
    }
  }

  @Test func diagnosticsPersistOnlyContentFreeAttemptMetadata() throws {
    let directory = URL.temporaryDirectory.appending(path: "gistpad-diagnostics-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let diagnostics = NoteAttemptDiagnostics(id: id, action: .ask, directory: directory)
    diagnostics.availability(
      "available", info: NoteModelInfo(variant: "Test model", contextSize: 4_096))
    diagnostics.measured(
      NoteModelPass(
        purpose: .answer, instruction: "PRIVATE REQUEST", source: "PRIVATE NOTE",
        responseTokens: 1_024, requestID: id),
      tokens: 241, schema: "answer-v2")
    diagnostics.response(length: 173)
    diagnostics.failed(NoteIntelligenceError.emptyAnswer)
    diagnostics.finish(errorCode: "emptyAnswer")
    let data = try Data(contentsOf: directory.appending(path: "\(id.uuidString).json"))
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("PRIVATE"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(NoteAttemptDiagnostics.Record.self, from: data)
    #expect(record.contextSize == 4_096)
    #expect(record.availability == "available")
    #expect(record.passes.first?.promptTokens == 241)
    #expect(record.passes.first?.schema == "answer-v2")
    #expect(record.responseLength == 173)
    #expect(record.errorType?.contains("NoteIntelligenceError") == true)
    #expect(record.outcome == "emptyAnswer")
    #expect(record.finishedAt != nil)
  }

  private func request(
    _ source: String, action: NoteIntelligenceAction = .edit, instruction: String,
    tasks: [NoteTask] = []
  ) -> NoteIntelligenceRequest {
    NoteIntelligenceRequest(
      snapshot: NoteSnapshot(
        documentID: "note.md", sessionID: UUID(), generation: 0, source: source, tasks: tasks),
      action: action, instruction: instruction)
  }

  private func task(_ id: Int, _ quote: String, in source: String, backwards: Bool = false)
    -> NoteTask
  {
    NoteTask(
      id: id, range: (source as NSString).range(of: quote, options: backwards ? .backwards : []),
      text: quote, isComplete: quote != "[ ]")
  }
}

@MainActor
private final class OutcomeModel: NoteModelBackend {
  var contextSize = 16_384
  var parts: [ModelAnswerPart] = []
  var operations: [NoteEditOperation] = []
  var lastPass: NoteModelPass?
  var editPasses: [NoteModelPass] = []

  func modelInfo() async throws -> NoteModelInfo {
    NoteModelInfo(variant: "Test", contextSize: contextSize)
  }
  func tokenCount(for pass: NoteModelPass) async throws -> Int { pass.source.utf16.count + 100 }
  func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation] {
    lastPass = pass
    editPasses.append(pass)
    return operations
  }
  func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] { [] }
  func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }
  func answer(
    for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
  ) async throws -> [ModelAnswerPart] {
    lastPass = pass
    onUpdate(parts)
    return parts
  }
}
