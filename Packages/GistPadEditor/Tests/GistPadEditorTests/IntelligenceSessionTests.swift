#if canImport(UIKit)
  import GistPadIntelligence
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct IntelligenceSessionTests {
    @Test func structuredTaskCompletionPreservesProtectedMarkdownAndHasOneNativeUndo() async throws
    {
      let source =
        "---\r\nexample: '- [ ] protected'\r\n---\r\n"
        + "# Today 👩🏽‍💻\r\n\r\n- [ ] Read café\r\n- [X] Already done\r\n"
        + "> - [ ] A quoted task\r\n  - [ ]\r\n\r\n"
        + "```markdown\r\n- [ ] Not a real task\r\n```\r\n"
        + "A sentence with `[ ]` and preserved spacing.  \r\n"
      let expected =
        source
        .replacingOccurrences(of: "- [ ] Read", with: "- [x] Read")
        .replacingOccurrences(of: "> - [ ] A", with: "> - [x] A")
        .replacingOccurrences(of: "  - [ ]\r\n", with: "  - [x]\r\n")
      let session = DocumentSession(documentID: "task-operation-undo", text: source)
      let window = host(session)
      defer { window.isHidden = true }
      let undo = try #require(session.textView.undoManager)
      undo.removeAllActions()
      let snapshot = try session.intelligenceSnapshot()
      #expect(snapshot.tasks.count == 4)
      #expect(snapshot.tasks.map(\.id) == [1, 2, 3, 4])
      #expect(snapshot.tasks.map(\.isComplete) == [false, true, false, false])
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let proposal = try await NoteIntelligenceEngine(backend: TaskOperationModel()).propose(
        NoteIntelligenceRequest(
          snapshot: snapshot, action: .edit, instruction: "すべてのタスクを完了にして"))
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(changes == 0)
      #expect(proposal.comments.count == 3)
      try session.applyIntelligenceProposal(proposal)
      #expect(session.text.utf8.elementsEqual(expected.utf8))
      #expect(session.generation == 1)
      #expect(changes == 1)
      undo.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(changes == 2)
      #expect(!undo.canUndo)
      undo.redo()
      session.textViewDidChange(session.textView)
      #expect(session.text.utf8.elementsEqual(expected.utf8))
    }

    @Test func applyingBehindAnIntelligenceSheetRetainsTheEditorsNativeUndo() throws {
      let session = DocumentSession(documentID: "background-ai-undo", text: "bad")
      let window = host(session)
      defer { window.isHidden = true }
      let undo = try #require(session.textView.undoManager)
      undo.removeAllActions()
      session.textView.resignFirstResponder()
      let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
      window.rootViewController?.view.addSubview(field)
      #expect(field.becomeFirstResponder())
      #expect(!session.textView.isFirstResponder)
      #expect(session.textView.undoManager === undo)
      let proposal = NoteProposal(
        snapshot: try session.intelligenceSnapshot(),
        candidates: [NoteReplacementCandidate(quote: "bad", replacement: "good", reason: "Clarity")]
      )
      try session.applyIntelligenceProposal(proposal)
      #expect(session.text == "good")
      #expect(undo.canUndo)
      field.resignFirstResponder()
      #expect(session.textView.becomeFirstResponder())
      #expect(session.textView.undoManager === undo)
      undo.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "bad")
      #expect(!undo.canUndo)
    }

    @Test func intelligenceUndoDoesNotConsumeEarlierNativeTyping() async throws {
      let session = DocumentSession(documentID: "mixed-ai-undo", text: "bad")
      let window = host(session)
      defer { window.isHidden = true }
      session.textView.undoManager?.removeAllActions()
      session.textView.selectedRange = NSRange(location: 3, length: 0)
      session.textView.insertText("!")
      session.textViewDidChange(session.textView)
      try await Task.sleep(for: .milliseconds(30))
      let proposal = NoteProposal(
        snapshot: try session.intelligenceSnapshot(),
        candidates: [NoteReplacementCandidate(quote: "bad", replacement: "good", reason: "Clarity")]
      )
      try session.applyIntelligenceProposal(proposal)
      #expect(session.text == "good!")
      session.textView.undoManager?.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "bad!")
      session.textView.undoManager?.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "bad")
      session.textView.undoManager?.redo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "bad!")
      session.textView.undoManager?.redo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "good!")
    }

    @Test func acceptingAnEntireNoteProposalIsOneNativeUndoAndOneCanonicalChange() throws {
      let source = "# Note\n\nA bad sentence.\n\nAnother typo."
      let session = DocumentSession(documentID: "ai", text: source)
      let window = host(session)
      defer { window.isHidden = true }
      session.textView.selectedRange = (source as NSString).range(of: "sentence")
      let selection = session.textView.selectedRange
      session.textView.undoManager?.removeAllActions()
      let snapshot = try session.intelligenceSnapshot()
      let proposal = NoteProposal(
        snapshot: snapshot,
        candidates: [
          NoteReplacementCandidate(quote: "bad", replacement: "clear", reason: "Clarity"),
          NoteReplacementCandidate(quote: "typo", replacement: "sentence", reason: "Correction"),
        ])
      var changes = 0
      var selectionAtCommit: NSRange?
      session.onSourceChange = { _, _ in
        changes += 1
        selectionAtCommit = session.selection
      }
      try session.applyIntelligenceProposal(proposal)
      #expect(session.text == "# Note\n\nA clear sentence.\n\nAnother sentence.")
      #expect(session.generation == 1)
      #expect(changes == 1)
      #expect(selectionAtCommit == session.textView.selectedRange)
      let appliedSelection = session.textView.selectedRange
      session.textView.undoManager?.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.textView.selectedRange == selection)
      #expect(selectionAtCommit == selection)
      #expect(changes == 2)
      #expect(session.textView.undoManager?.canUndo == false)
      session.textView.undoManager?.redo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "# Note\n\nA clear sentence.\n\nAnother sentence.")
      #expect(session.textView.selectedRange == appliedSelection)
      #expect(selectionAtCommit == appliedSelection)
      #expect(changes == 3)
    }

    @Test func reviewCommentsApplyIndividuallyWithDeterministicallyUpdatedAnchors() throws {
      let session = DocumentSession(documentID: "review", text: "bad and typo")
      let window = host(session)
      defer { window.isHidden = true }
      let original = try session.intelligenceSnapshot()
      let proposal = NoteProposal(
        snapshot: original,
        candidates: [
          NoteReplacementCandidate(quote: "bad", replacement: "much better", reason: "Clarity"),
          NoteReplacementCandidate(quote: "typo", replacement: "word", reason: "Correction"),
        ])
      let remaining = try session.applyIntelligenceProposal(
        proposal, commentID: proposal.comments[0].id)
      #expect(session.text == "much better and typo")
      #expect(remaining.comments.count == 1)
      #expect(remaining.comments[0].canApply)
      try session.applyIntelligenceProposal(remaining, commentID: remaining.comments[0].id)
      #expect(session.text == "much better and word")
      #expect(session.generation == 2)
    }

    @Test func staleDifferentSessionAndReadOnlyProposalsNeverChangeTextOrUndo() throws {
      let session = DocumentSession(documentID: "stale-ai", text: "bad")
      let window = host(session)
      defer { window.isHidden = true }
      session.textView.undoManager?.removeAllActions()
      let snapshot = try session.intelligenceSnapshot()
      let proposal = NoteProposal(
        snapshot: snapshot,
        candidates: [NoteReplacementCandidate(quote: "bad", replacement: "good", reason: "Fix")])
      let other = DocumentSession(documentID: session.documentID, text: session.text)
      #expect(throws: NoteIntelligenceError.self) { try other.applyIntelligenceProposal(proposal) }
      session.textView.isEditable = false
      #expect(try session.intelligenceSnapshot() == snapshot)
      #expect(throws: NoteIntelligenceError.self) {
        try session.applyIntelligenceProposal(proposal)
      }
      session.textView.isEditable = true
      try session.apply(
        SourceMutation(range: NSRange(location: 0, length: 3), expected: "bad", replacement: "new"),
        documentID: session.documentID, generation: 0)
      session.textView.undoManager?.removeAllActions()
      #expect(throws: NoteIntelligenceError.self) {
        try session.applyIntelligenceProposal(proposal)
      }
      #expect(session.text == "new")
      #expect(session.generation == 1)
      #expect(session.textView.undoManager?.canUndo == false)
    }

    @Test func writingToolsAndCompositionCannotProduceOrApplyASnapshot() throws {
      let session = DocumentSession(documentID: "busy-ai", text: "bad")
      let window = host(session)
      defer { window.isHidden = true }
      session.textViewWritingToolsWillBegin(session.textView)
      #expect(throws: NoteIntelligenceError.self) { try session.intelligenceSnapshot() }
      session.textViewWritingToolsDidEnd(session.textView)
      session.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
      #expect(throws: NoteIntelligenceError.self) { try session.intelligenceSnapshot() }
      session.textView.unmarkText()
    }

    private func host(_ session: DocumentSession) -> UIWindow {
      let controller = UIHostingController(rootView: MarkdownEditorView(session: session))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = controller
      window.makeKeyAndVisible()
      controller.view.layoutIfNeeded()
      session.textView.becomeFirstResponder()
      return window
    }
  }

  @MainActor
  private final class TaskOperationModel: NoteModelBackend {
    func modelInfo() async throws -> NoteModelInfo {
      NoteModelInfo(variant: "Test", contextSize: 16_384)
    }
    func tokenCount(for pass: NoteModelPass) async throws -> Int { pass.source.utf16.count + 100 }
    func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation] {
      [.setTaskStates(ids: nil, isComplete: true)]
    }
    func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] { [] }
    func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }
    func answer(
      for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
    ) async throws -> [ModelAnswerPart] { [] }
  }
#endif
