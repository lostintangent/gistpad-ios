#if canImport(UIKit)
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct FormattingSessionTests {
    @Test func formattingIsOneNativeUndoWithFinalSelection() throws {
      let session = DocumentSession(documentID: "format", text: "A 日本語 note")
      let window = host(session)
      defer { window.isHidden = true }
      let originalSelection = (session.text as NSString).range(of: "日本語")
      session.textView.selectedRange = originalSelection
      session.textView.undoManager?.removeAllActions()
      var savedSelection: NSRange?
      var changes = 0
      session.onSourceChange = { _, _ in
        savedSelection = session.selection
        changes += 1
      }
      let edit = try #require(
        try MarkdownFormatting.edit(.bold, in: session.text, selection: originalSelection))
      try session.apply(edit, generation: 0)
      #expect(session.text == "A **日本語** note")
      #expect(session.textView.selectedRange == edit.selection)
      #expect(savedSelection == edit.selection)
      #expect(changes == 1)
      #expect(session.generation == 1)
      session.textView.undoManager?.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "A 日本語 note")
      #expect(session.textView.selectedRange == originalSelection)
      #expect(session.textView.undoManager?.canUndo == false)
      session.textView.undoManager?.redo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "A **日本語** note")
    }

    @Test func staleLinkAndInvalidResultSelectionNeverChangeSource() throws {
      let session = DocumentSession(documentID: "link", text: "note")
      let edit = try #require(
        try MarkdownFormatting.edit(
          .link(label: "note", destination: "https://example.com"),
          in: session.text, selection: NSRange(location: 0, length: 4)))
      #expect(throws: SourceMutation.MutationError.staleGeneration) {
        try session.apply(edit, generation: 1)
      }
      let invalid = SourceEdit(
        mutation: edit.mutation, selection: NSRange(location: 900, length: 0))
      #expect(throws: SourceMutation.MutationError.invalidRange) {
        try session.apply(invalid, generation: 0)
      }
      #expect(session.text == "note")
      #expect(session.generation == 0)
    }

    @Test func compositionWritingToolsAndReadOnlyBlockFormatting() throws {
      let session = DocumentSession(documentID: "blocked", text: "note")
      let window = host(session)
      defer { window.isHidden = true }
      let edit = try #require(
        try MarkdownFormatting.edit(
          .bold, in: session.text, selection: NSRange(location: 0, length: 4)))
      session.textViewWritingToolsWillBegin(session.textView)
      #expect(throws: SourceMutation.MutationError.compositionActive) {
        try session.apply(edit, generation: 0)
      }
      session.textViewWritingToolsDidEnd(session.textView)
      session.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
      #expect(!session.canFormat)
      #expect(throws: SourceMutation.MutationError.compositionActive) {
        try session.apply(edit, generation: 0)
      }
      session.textView.unmarkText()
      session.textViewDidChange(session.textView)
      session.textView.isEditable = false
      #expect(!session.canFormat)
    }

    @Test func wrapperReusesTheSessionTextViewAndEnablesNativeFind() throws {
      let session = DocumentSession(documentID: "wrapper", text: "note")
      let identity = ObjectIdentifier(session.textView)
      let window = host(session)
      defer { window.isHidden = true }
      #expect(ObjectIdentifier(session.textView) == identity)
      #expect(session.isEditing)
      #expect(session.textView.isFindInteractionEnabled)
      #expect(session.textView.findInteraction != nil)
      session.textView.resignFirstResponder()
      #expect(!session.isEditing)
    }

    private func host(_ session: DocumentSession) -> UIWindow {
      // Package logic tests have no connected UIWindowScene.
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = UIHostingController(
        rootView: MarkdownEditorView(session: session))
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
      session.textView.becomeFirstResponder()
      return window
    }
  }
#endif
