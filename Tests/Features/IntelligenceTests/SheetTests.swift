#if canImport(UIKit)
  @testable import Editor
  import SwiftUI
  import Testing
  import UIKit

  @testable import Intelligence

  @Suite(.serialized)
  @MainActor
  struct SheetTests {
    private let source = FixtureLanguageModel.source

    @Test func nothingChangesUntilApplyAndApplyIsOneUndo() async throws {
      let editor = Editor(text: source)
      let window = host(editor)
      defer { window.isHidden = true }
      let undo = try #require(editor.textView.undoManager)
      undo.removeAllActions()
      editor.textView.selectedRange = NSRange(location: source.utf16.count, length: 0)
      editor.textView.insertText("!")
      editor.textViewDidChange(editor.textView)
      try await Task.sleep(for: .milliseconds(30))
      let typed = source + "!"
      var changes = 0
      editor.onEdit = { _, _ in changes += 1 }
      let state = IntelligenceState(editor: editor, backend: FixtureLanguageModel())
      state.action = .edit
      state.editPrompt = "Fix the typo and the time"
      state.generate()
      await state.task?.value
      #expect(state.canApply)
      #expect(changes == 0)
      #expect(editor.text == typed)

      let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
      window.rootViewController?.view.addSubview(field)
      #expect(field.becomeFirstResponder())
      let selection = editor.textView.selectedRange
      let generation = editor.generation
      state.apply()
      let edited = typed.replacingOccurrences(of: "teh", with: "the")
        .replacingOccurrences(of: "before the cafe", with: "after the cafe")
      #expect(state.errorMessage == nil)
      #expect(editor.text == edited)
      #expect(editor.generation == generation + 1)
      #expect(changes == 1)
      #expect(state.appliedCount == 2)

      field.resignFirstResponder()
      #expect(editor.textView.becomeFirstResponder())
      #expect(editor.textView.undoManager === undo)
      for expected in [typed, source] {
        undo.undo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == expected)
        if expected == typed { #expect(editor.textView.selectedRange == selection) }
      }
      for expected in [typed, edited] {
        undo.redo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == expected)
      }
    }

    enum AskFailure: Sendable {
      case unavailable, error(IntelligenceError), answer(ModelAnswer)
    }

    @Test(arguments: [
      AskFailure.unavailable, .error(.refused), .answer(ModelAnswer(prose: " \r\n\t")),
    ])
    func everyFailedAskShowsAReasonAndKeepsTheRequestAndFile(failure: AskFailure) async {
      let editor = Editor(text: source)
      var changes = 0
      editor.onEdit = { _, _ in changes += 1 }
      let fixture = FixtureLanguageModel()
      switch failure {
      case .unavailable: fixture.unavailableReason = "Apple Intelligence is turned off."
      case .error(let error): fixture.failure = error
      case .answer(let answer): fixture.answer = answer
      }
      let state = IntelligenceState(editor: editor, backend: fixture)
      state.askPrompt = "When do I leave?"
      state.generate()
      await state.task?.value
      let reason = state.errorMessage ?? state.availabilityReason ?? ""
      #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!state.isRunning)
      #expect(state.answerParts.isEmpty)
      #expect(state.askPrompt == "When do I leave?")
      #expect(editor.text == source)
      #expect(editor.generation == 0)
      #expect(changes == 0)
    }

    @Test func cancelKeepsTheRequestAndTheFile() async {
      let editor = Editor(text: source)
      let fixture = FixtureLanguageModel()
      fixture.delay = .seconds(5)
      let state = IntelligenceState(editor: editor, backend: fixture)
      state.askPrompt = "When do I leave?"
      state.generate()
      var spins = 0
      while fixture.passes.isEmpty, spins < 1_000 {
        spins += 1
        await Task.yield()
      }
      #expect(state.isRunning)
      state.cancel()
      await state.task?.value
      #expect(!state.isRunning)
      #expect(state.answerParts.isEmpty)
      #expect(state.notice != nil)
      #expect(state.errorMessage == nil)
      #expect(state.askPrompt == "When do I leave?")
      #expect(editor.text == source)
      #expect(editor.generation == 0)
    }

    @Test func aReadOnlyFileAllowsAskAndReviewButNotEditOrApply() async {
      let editor = Editor(text: source)
      editor.isEditable = false
      let state = IntelligenceState(editor: editor, backend: FixtureLanguageModel())
      state.askPrompt = "When do I leave?"
      #expect(state.canGenerate)
      state.action = .edit
      state.editPrompt = "Fix the typo"
      #expect(!state.canGenerate)
      state.action = .review
      #expect(state.canGenerate)
      state.generate()
      await state.task?.value
      #expect(state.proposal?.changes.count == 2)
      #expect(!state.canApply)
      state.apply()
      #expect(editor.text == source)
      #expect(editor.generation == 0)
    }

    @Test(arguments: [false, true])
    func citationsOnlyLinkToVisibleBodyEvenWhenMetadataRepeatsTheQuote(shown: Bool) async throws {
      let prefix = "---\nkey: e\u{301} 👩🏽‍💻\n---\n\n"
      let text = prefix + "# Content\n\nA retained thought about e\u{301} 👩🏽‍💻."
      let editor = Editor(text: text, generation: 8, showsFrontMatter: shown)
      let fixture = FixtureLanguageModel()
      fixture.answer = ModelAnswer(
        prose: "You retained this thought.", quotes: ["e\u{301} 👩🏽‍💻"])
      let state = IntelligenceState(editor: editor, backend: fixture)
      state.askPrompt = "What thought did I retain?"
      state.generate()
      await state.task?.value
      guard case .quotation(_, let ranges) = try #require(state.answerParts.last) else {
        Issue.record("Expected a verified quotation")
        return
      }
      let reference = try #require(ranges.first)
      #expect(ranges.count == 1)
      #expect(reference.location >= prefix.utf16.count)
      #expect(!state.isStale)
      editor.setShowsFrontMatter(!shown)
      #expect(!state.isStale)
      editor.setShowsFrontMatter(shown)
      #expect(editor.text.utf8.elementsEqual(text.utf8))
      #expect(editor.generation == 8)
    }

    private func host(_ editor: Editor) -> UIWindow {
      let controller = UIHostingController(rootView: EditorView(editor: editor))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = controller
      window.makeKeyAndVisible()
      controller.view.layoutIfNeeded()
      editor.textView.becomeFirstResponder()
      return window
    }
  }
#endif
