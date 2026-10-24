#if canImport(UIKit)
  import GistPadIntelligence
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct IntelligenceModelTests {
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
    var available = true
    var lastPass: NoteModelPass?
    var parts = [ModelAnswerPart(kind: .prose, text: "An answer")]

    func modelInfo() async throws -> NoteModelInfo {
      guard available else { throw NoteIntelligenceError.unavailable("Model not ready") }
      return NoteModelInfo(variant: "Fake", contextSize: 4_096)
    }

    func tokenCount(for pass: NoteModelPass) async throws -> Int { pass.source.utf16.count + 100 }

    func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
      lastPass = pass
      return [NoteReplacementCandidate(quote: "bad", replacement: "good", reason: "Clarity")]
    }

    func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }

    func answer(
      for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
    ) async throws -> [ModelAnswerPart] {
      onUpdate(parts)
      return parts
    }
  }
#endif
