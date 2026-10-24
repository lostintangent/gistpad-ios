#if canImport(UIKit)
  import GistPadIntelligence
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct IntelligenceSessionTests {
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
#endif
