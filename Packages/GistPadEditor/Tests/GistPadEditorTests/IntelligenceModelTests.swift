#if canImport(UIKit)
  import GistPadIntelligence
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct IntelligenceModelTests {
    @Test(arguments: [false, true])
    func hiddenMetadataReferencesHaveNoRevealActionAndFollowTheVisibilityPreference(
      shown: Bool
    ) async throws {
      let prefix = "---\nkey: e\u{301} 👩🏽‍💻\n---\n\n"
      let source = prefix + "# Content\n\nA retained thought."
      let session = DocumentSession(
        documentID: "metadata-reference", text: source, generation: 8, showsFrontMatter: shown)
      session.textView.selectedRange = (source as NSString).range(of: "retained")
      let identity = session.viewIdentity
      let selection = session.textView.selectedRange
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let model = NoteIntelligenceModel(
        session: session, backend: SheetModel(), isCurrent: { true })
      model.askPrompt = "What does this note say?"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      try #require(model.snapshot != nil)
      for (range, metadata) in [
        ((source as NSString).range(of: "e\u{301} 👩🏽‍💻"), true),
        (NSRange(location: prefix.utf16.count - 1, length: 3), true),
        ((source as NSString).range(of: "retained"), false),
      ] {
        try #require(Range(range, in: source) != nil)
        #expect(model.isHiddenFrontMatterReference(range) == (metadata && !shown))
        #expect(model.canReveal(range) == !(metadata && !shown))
        session.setShowsFrontMatter(!shown)
        #expect(model.isHiddenFrontMatterReference(range) == (metadata && shown))
        #expect(model.canReveal(range) == !(metadata && shown))
        session.setShowsFrontMatter(shown)
      }
      #expect(session.viewIdentity == identity)
      #expect(session.textView.selectedRange == selection)
      #expect(session.showsFrontMatter == shown)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 8)
      #expect(session.textView.undoManager?.canUndo != true)
      #expect(changes == 0)
    }

    @Test func dailyNoteInstructionEchoIsRejectedBeforeTheSheetOffersApply() async {
      let source = "## 📆 2026-10-24\n\n- [ ]"
      let instruction = "mark everything complete"
      let session = DocumentSession(documentID: "daily-echo", text: source)
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let backend = SheetModel()
      backend.candidates = [
        NoteReplacementCandidate(quote: source, replacement: instruction, reason: "Mark complete")
      ]
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.action = .edit
      model.editPrompt = instruction
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(model.proposal == nil)
      #expect(!model.canApply)
      #expect(model.errorMessage?.isEmpty == false)
      #expect(backend.finishedCode == "unsafeEdit")
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(changes == 0)
    }

    @Test(arguments: [
      NoteIntelligenceError.emptyAnswer, .refused, .timedOut,
      .insufficientContext, .unavailable(""), .rateLimited,
    ])
    func everyFailedMangaAskEndsWithAVisibleReasonAndNoSourceChange(
      failure: NoteIntelligenceError
    ) async {
      let source = "# Manga Reading\n\n### Reading\n1. Frieren, volume 8\n2. Yotsuba&!\n"
      let session = DocumentSession(documentID: "manga-outcome", text: source)
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let backend = SheetModel()
      backend.answerFailure = failure
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "What's the summary of the manga reading list?"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(!model.isRunning)
      #expect(model.answerParts.isEmpty)
      #expect(model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      #expect(backend.beganID == backend.lastPass?.requestID)
      #expect(backend.finishedID == backend.beganID)
      #expect(backend.finishedCode == failure.diagnosticCode)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(changes == 0)
    }

    @Test(arguments: [[], [ModelAnswerPart(kind: .prose, text: " \r\n\t")]])
    func emptyAndWhitespaceAnswersCannotFinishAsAnEmptySheet(parts: [ModelAnswerPart]) async {
      let session = DocumentSession(documentID: "empty-answer", text: "# Reading\n\n1. Frieren")
      let backend = SheetModel()
      backend.parts = parts
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "Summarize"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(!model.isRunning)
      #expect(model.answerParts.isEmpty)
      #expect(model.errorMessage?.isEmpty == false)
      #expect(backend.finishedCode == "emptyAnswer")
      #expect(session.generation == 0)
    }

    @Test func resultSummaryKeepsTheSubmittedRequestUntilTheRequestIsEdited() async {
      let session = DocumentSession(documentID: "model-summary", text: "Unchanged source")
      let model = NoteIntelligenceModel(
        session: session, backend: SheetModel(), isCurrent: { true })
      model.askPrompt = "What does this note say?"
      #expect(!model.hasResults)
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(model.hasResults)
      #expect(model.submittedPrompt == "What does this note say?")
      model.askPrompt = "Explain it more simply."
      #expect(model.submittedPrompt == "What does this note say?")
      model.clearResults()
      #expect(!model.hasResults)
      #expect(model.submittedPrompt == nil)
      #expect(model.askPrompt == "Explain it more simply.")
      #expect(session.text == "Unchanged source")
      #expect(session.generation == 0)
    }

    @Test func cancellingAStreamingAnswerClearsItsPartialTextAndPreservesTheRequest() async {
      let session = DocumentSession(documentID: "model-cancel", text: "Unchanged source")
      let backend = SheetModel()
      backend.waitForCancellation = true
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "What does this note say?"
      await model.checkAvailability()
      await withCheckedContinuation { continuation in
        backend.onAnswer = { continuation.resume() }
        model.generate()
      }
      #expect(model.isRunning)
      #expect(!model.answerParts.isEmpty)
      model.cancel()
      await model.task?.value
      #expect(!model.isRunning)
      #expect(!model.isCancelling)
      #expect(model.answerParts.isEmpty)
      #expect(model.proposal == nil)
      #expect(model.notice != nil)
      #expect(model.errorMessage == nil)
      #expect(model.askPrompt == "What does this note say?")
      #expect(session.text == "Unchanged source")
      #expect(session.generation == 0)
      #expect(model.applyFeedback == 0)
    }

    @Test func applyingAReviewCommentRebasesTheSheetWithoutGeneratingAgain() async throws {
      let session = DocumentSession(documentID: "model-rebase", text: "bad and typo")
      let backend = SheetModel()
      backend.candidates = [
        NoteReplacementCandidate(quote: "bad", replacement: "much better", reason: "Clarity"),
        NoteReplacementCandidate(quote: "typo", replacement: "word", reason: "Correction"),
      ]
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.action = .review
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      let original = try #require(model.proposal)
      model.apply(commentID: original.comments[0].id)
      let remaining = try #require(model.proposal)
      #expect(backend.replacementCalls == 1)
      #expect(!model.isStale)
      #expect(remaining.comments.count == 1)
      #expect(remaining.comments[0].id == original.comments[1].id)
      #expect(remaining.comments[0].canApply)
      model.apply(commentID: remaining.comments[0].id)
      #expect(backend.replacementCalls == 1)
      #expect(model.proposal?.comments.isEmpty == true)
      #expect(model.appliedCount == 2)
      #expect(model.errorMessage == nil)
      #expect(session.text == "much better and word")
      #expect(session.generation == 2)
    }

    @Test func reviewDoesNotReuseAnEarlierAskInstruction() async throws {
      let session = DocumentSession(documentID: "model-review", text: "bad")
      let backend = SheetModel()
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "An unrelated question"
      model.action = .review
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      let pass = try #require(backend.lastPass)
      #expect(pass.purpose == .review)
      #expect(pass.instruction.isEmpty)
      #expect(model.proposal != nil)
      #expect(session.text == "bad")
      #expect(session.generation == 0)
    }

    @Test func generationNeverPublishesOrTouchesCanonicalSourceUntilApply() async throws {
      let session = DocumentSession(documentID: "model-edit", text: "bad")
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let backend = SheetModel()
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.action = .edit
      model.editPrompt = "Fix the wording"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(model.proposal?.canApply == true)
      #expect(changes == 0)
      #expect(session.text == "bad")
      #expect(model.applyFeedback == 0)
      model.apply()
      #expect(model.errorMessage == nil)
      #expect(session.text == "good")
      #expect(changes == 1)
      #expect(model.appliedCount == 1)
      #expect(model.applyFeedback == 1)
      model.clearResults()
      #expect(model.appliedCount == 0)
      #expect(model.applyFeedback == 1)
    }

    @Test func changingTheCurrentAccountOrDocumentDisablesAndRejectsApply() async {
      let session = DocumentSession(documentID: "model-current", text: "bad")
      var current = true
      let model = NoteIntelligenceModel(
        session: session, backend: SheetModel(), isCurrent: { current })
      model.action = .edit
      model.editPrompt = "Fix"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      current = false
      #expect(model.isStale)
      #expect(!model.canApply)
      model.apply()
      #expect(model.errorMessage != nil)
      #expect(session.text == "bad")
      #expect(session.generation == 0)
    }

    @Test func unavailableAndUnverifiedResponsesKeepTheRequestAndShowAReason() async {
      let session = DocumentSession(documentID: "model-errors", text: "Real source")
      let backend = SheetModel()
      backend.available = false
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "Quote this note"
      await model.checkAvailability()
      #expect(!model.canGenerate)
      #expect(model.availabilityReason != nil)
      #expect(model.askPrompt == "Quote this note")
      backend.available = true
      backend.parts = [ModelAnswerPart(kind: .quote, text: "Invented source")]
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(model.errorMessage != nil)
      #expect(model.answerParts.isEmpty)
      #expect(model.askPrompt == "Quote this note")
      #expect(session.text == "Real source")
      #expect(session.generation == 0)
    }

    @Test func readOnlyNotesAllowAskAndReviewButNotEdit() async {
      let session = DocumentSession(documentID: "model-readonly", text: "bad")
      session.textView.isEditable = false
      let model = NoteIntelligenceModel(
        session: session, backend: SheetModel(), isCurrent: { true })
      await model.checkAvailability()
      model.askPrompt = "What is this?"
      #expect(model.canGenerate)
      model.action = .review
      #expect(model.canGenerate)
      model.action = .edit
      model.editPrompt = "Fix"
      #expect(!model.canGenerate)
      #expect(!model.canApply)
    }
  }

  @MainActor
  private final class SheetModel: NoteModelBackend {
    var answerFailure: NoteIntelligenceError?
    var beganID: UUID?
    var finishedID: UUID?
    var finishedCode: String?
    var available = true
    var waitForCancellation = false
    var onAnswer: (() -> Void)?
    var replacementCalls = 0
    var lastPass: NoteModelPass?
    var parts = [ModelAnswerPart(kind: .prose, text: "An answer")]
    var candidates = [
      NoteReplacementCandidate(quote: "bad", replacement: "good", reason: "Clarity")
    ]

    func beginAttempt(id: UUID, action: NoteIntelligenceAction) { beganID = id }
    func finishAttempt(id: UUID, errorCode: String?, errorType: String?) {
      finishedID = id
      finishedCode = errorCode
    }

    func modelInfo() async throws -> NoteModelInfo {
      guard available else { throw NoteIntelligenceError.unavailable("Model not ready") }
      return NoteModelInfo(variant: "Fake", contextSize: 4_096)
    }

    func tokenCount(for pass: NoteModelPass) async throws -> Int { pass.source.utf16.count + 100 }

    func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
      lastPass = pass
      replacementCalls += 1
      return candidates
    }

    func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }

    func answer(
      for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
    ) async throws -> [ModelAnswerPart] {
      lastPass = pass
      onUpdate(parts)
      if let answerFailure { throw answerFailure }
      onAnswer?()
      if waitForCancellation { try await Task.sleep(for: .seconds(5)) }
      return parts
    }
  }
#endif
