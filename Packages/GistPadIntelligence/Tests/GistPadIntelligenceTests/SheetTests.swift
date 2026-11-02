#if canImport(UIKit)
  import GistPadEditor
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPadIntelligence

  @Suite(.serialized)
  @MainActor
  struct SheetTests {
    private let source = FixtureModel.source

    @Test func nothingChangesUntilApplyAndApplyIsOneUndo() async throws {
      let session = Editor(fileID: "apply-undo", text: source)
      let window = host(session)
      defer { window.isHidden = true }
      let undo = try #require(session.textView.undoManager)
      undo.removeAllActions()
      session.textView.selectedRange = NSRange(location: source.utf16.count, length: 0)
      session.textView.insertText("!")
      session.textViewDidChange(session.textView)
      try await Task.sleep(for: .milliseconds(30))
      let typed = source + "!"
      var changes = 0
      session.onEdit = { _, _ in changes += 1 }
      let model = IntelligenceState(session: session, backend: FixtureModel())
      model.action = .edit
      model.editPrompt = "Fix the typo and the time"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      #expect(model.canApply)
      #expect(changes == 0)
      #expect(session.text == typed)

      let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
      window.rootViewController?.view.addSubview(field)
      #expect(field.becomeFirstResponder())
      let selection = session.textView.selectedRange
      let generation = session.generation
      model.apply()
      let edited = typed.replacingOccurrences(of: "teh", with: "the")
        .replacingOccurrences(of: "before the cafe", with: "after the cafe")
      #expect(model.errorMessage == nil)
      #expect(session.text == edited)
      #expect(session.generation == generation + 1)
      #expect(changes == 1)

      field.resignFirstResponder()
      #expect(session.textView.becomeFirstResponder())
      #expect(session.textView.undoManager === undo)
      for expected in [typed, source] {
        undo.undo()
        session.textViewDidChange(session.textView)
        #expect(session.text == expected)
        if expected == typed { #expect(session.textView.selectedRange == selection) }
      }
      for expected in [typed, edited] {
        undo.redo()
        session.textViewDidChange(session.textView)
        #expect(session.text == expected)
      }
    }

    enum AskFailure: Sendable {
      case unavailable, error(IntelligenceError), answer([ModelAnswerPart])
    }

    @Test(arguments: [
      AskFailure.unavailable, .error(.refused), .error(.timedOut), .error(.rateLimited),
      .error(.insufficientContext), .error(.unavailable("")), .answer([]),
      .answer([ModelAnswerPart(kind: .prose, text: " \r\n\t")]),
      .answer([ModelAnswerPart(kind: .quote, text: "Invented source")]),
      .answer([ModelAnswerPart(kind: .prose, text: "The user leaves at 9am.")]),
    ])
    func everyFailedAskShowsAReasonAndKeepsTheRequestAndFile(failure: AskFailure) async {
      let session = Editor(fileID: "failed-ask", text: source)
      var changes = 0
      session.onEdit = { _, _ in changes += 1 }
      let fixture = FixtureModel()
      switch failure {
      case .unavailable: fixture.unavailableReason = "Apple Intelligence is turned off."
      case .error(let error): fixture.failure = error
      case .answer(let parts): fixture.answer = parts
      }
      let model = IntelligenceState(session: session, backend: fixture)
      model.askPrompt = "When do I leave?"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      let reason = model.errorMessage ?? model.availabilityReason ?? ""
      #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!model.isRunning)
      #expect(model.answerParts.isEmpty)
      #expect(model.askPrompt == "When do I leave?")
      #expect(session.text == source)
      #expect(session.generation == 0)
      #expect(changes == 0)
    }

    @Test func cancelKeepsTheRequestAndTheFile() async {
      let session = Editor(fileID: "cancel", text: source)
      let fixture = FixtureModel()
      fixture.delay = .seconds(5)
      let model = IntelligenceState(session: session, backend: fixture)
      model.askPrompt = "When do I leave?"
      await model.checkAvailability()
      model.generate()
      var spins = 0
      while fixture.passes.isEmpty, spins < 1_000 {
        spins += 1
        await Task.yield()
      }
      #expect(model.isRunning)
      model.cancel()
      await model.task?.value
      #expect(!model.isRunning)
      #expect(model.answerParts.isEmpty)
      #expect(model.notice != nil)
      #expect(model.errorMessage == nil)
      #expect(model.askPrompt == "When do I leave?")
      #expect(session.text == source)
      #expect(session.generation == 0)
    }

    @Test func aReadOnlyFileAllowsAskAndReviewButNotEditOrApply() async {
      let session = Editor(fileID: "read-only", text: source)
      session.textView.isEditable = false
      let model = IntelligenceState(session: session, backend: FixtureModel())
      await model.checkAvailability()
      model.askPrompt = "When do I leave?"
      #expect(model.canGenerate)
      model.action = .edit
      model.editPrompt = "Fix the typo"
      #expect(!model.canGenerate)
      model.action = .review
      #expect(model.canGenerate)
      model.generate()
      await model.task?.value
      #expect(model.review?.comments.count == 2)
      #expect(!model.canApply)
      model.apply()
      #expect(session.text == source)
      #expect(session.generation == 0)
    }

    @Test(arguments: [false, true])
    func aCitationIntoHiddenFrontMatterShowsItsQuoteWithoutShowInFile(shown: Bool) async throws {
      let prefix = "---\nkey: e\u{301} 👩🏽‍💻\n---\n\n"
      let text = prefix + "# Content\n\nA retained thought."
      let session = Editor(
        fileID: "front-matter", text: text, generation: 8, showsFrontMatter: shown)
      let fixture = FixtureModel()
      fixture.answer = [
        ModelAnswerPart(kind: .prose, text: "Your key is set."),
        ModelAnswerPart(kind: .quote, text: "key: e\u{301} 👩🏽‍💻"),
      ]
      let model = IntelligenceState(session: session, backend: fixture)
      model.askPrompt = "What is my key?"
      await model.checkAvailability()
      model.generate()
      await model.task?.value
      guard case .quotation(let citation) = try #require(model.answerParts.last) else {
        Issue.record("Expected a verified quotation")
        return
      }
      let metadata = try #require(citation.ranges.first)
      #expect(model.canReveal(metadata) == shown)
      session.setShowsFrontMatter(!shown)
      #expect(model.canReveal(metadata) == !shown)
      session.setShowsFrontMatter(shown)
      #expect(model.canReveal((text as NSString).range(of: "retained")))
      #expect(session.text.utf8.elementsEqual(text.utf8))
      #expect(session.generation == 8)
    }

    private func host(_ session: Editor) -> UIWindow {
      let controller = UIHostingController(rootView: EditorView(session: session))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = controller
      window.makeKeyAndVisible()
      controller.view.layoutIfNeeded()
      session.textView.becomeFirstResponder()
      return window
    }
  }
#endif
