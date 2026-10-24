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

    @Test func smartReturnAndURLPasteUseOneNativeUndo() throws {
      for (source, range, replacement, expected) in [
        ("- First", NSRange(location: 7, length: 0), "\n", "- First\n- "),
        ("1. First\n2. Next", NSRange(location: 8, length: 0), "\n", "1. First\n2. \n3. Next"),
        (
          "Open note", NSRange(location: 5, length: 4), "https://example.com",
          "Open [note](https://example.com)"
        ),
      ] {
        let session = DocumentSession(documentID: "typing", text: source)
        let window = host(session)
        defer { window.isHidden = true }
        session.textView.selectedRange = range
        session.textView.undoManager?.removeAllActions()
        #expect(
          !session.textView(
            session.textView, shouldChangeTextIn: range, replacementText: replacement))
        #expect(session.text == expected)
        #expect(session.generation == 1)
        session.textView.undoManager?.undo()
        session.textViewDidChange(session.textView)
        #expect(session.text == source)
        #expect(session.textView.undoManager?.canUndo == false)
      }
    }

    @Test func smartTypingYieldsToCompositionWritingToolsAndProtectedSyntax() {
      for source in ["```\n- code", "---\n- metadata", "Ordinary prose"] {
        let session = DocumentSession(documentID: "protected", text: source)
        let caret = NSRange(location: source.utf16.count, length: 0)
        #expect(
          session.textView(session.textView, shouldChangeTextIn: caret, replacementText: "\n"))
        #expect(session.text == source)
      }
      let session = DocumentSession(documentID: "composing", text: "- note")
      let window = host(session)
      defer { window.isHidden = true }
      session.textViewWritingToolsWillBegin(session.textView)
      #expect(
        session.textView(
          session.textView, shouldChangeTextIn: NSRange(location: 6, length: 0),
          replacementText: "\n"))
      session.textViewWritingToolsDidEnd(session.textView)
      session.textView.selectedRange = NSRange(location: 6, length: 0)
      session.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
      let transient = session.textView.text
      #expect(
        session.textView(
          session.textView, shouldChangeTextIn: session.textView.selectedRange,
          replacementText: "\n"))
      #expect(session.textView.text == transient)
    }

    @Test func indentAndOutdentRetainSelectionAndNativeUndo() throws {
      let session = DocumentSession(documentID: "indent", text: "- 日本語\n- next")
      let window = host(session)
      defer { window.isHidden = true }
      let original = session.text
      session.textView.selectedRange = NSRange(location: 0, length: original.utf16.count)
      session.textView.undoManager?.removeAllActions()
      try session.indent(outdent: false)
      #expect(session.text == "  - 日本語\n  - next")
      #expect(
        session.textView.selectedRange == NSRange(location: 2, length: original.utf16.count + 2))
      session.textView.undoManager?.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == original)
      #expect(session.textView.undoManager?.canUndo == false)
    }

    @Test func nativeInputAccessoryIsMountedAndItsBoldActionEditsTheActiveSession() throws {
      let session = DocumentSession(documentID: "accessory", text: "A note")
      let window = host(session)
      defer { window.isHidden = true }
      let toolbar = try #require(session.textView.inputAccessoryView as? UIToolbar)
      #expect(toolbar.accessibilityIdentifier == "editor-keyboard-bar")
      let items = try #require(toolbar.items)
      #expect(items.count == 8)
      let bold = try #require(items.first { $0.accessibilityLabel == "Bold" })
      let selector = try #require(bold.action)
      session.textView.selectedRange = NSRange(location: 2, length: 4)
      session.textView.undoManager?.removeAllActions()
      #expect(UIApplication.shared.sendAction(selector, to: bold.target, from: bold, for: nil))
      #expect(session.text == "A **note**")
      #expect(session.generation == 1)
      session.textView.undoManager?.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "A note")
      #expect(session.textView.undoManager?.canUndo == false)
      let insertion = try #require(
        items.first { $0.accessibilityIdentifier == "editor-insert-menu" })
      #expect(insertion.menu != nil)
      #expect(items.first { $0.accessibilityLabel == "Lists" }?.menu?.children.count == 5)
      #expect(items.first { $0.accessibilityLabel == "Find" }?.menu?.children.count == 2)
      #expect(session.textView.keyCommands?.contains { $0.input == "]" } == true)
      let dismiss = try #require(items.first { $0.accessibilityLabel == "Hide Keyboard" })
      let hide = try #require(dismiss.action)
      #expect(UIApplication.shared.sendAction(hide, to: dismiss.target, from: dismiss, for: nil))
      #expect(!session.textView.isFirstResponder)
    }

    @Test func nativeFindAndReplaceKeepsURLReplacementsLiteral() async throws {
      let session = DocumentSession(documentID: "find", text: "A note and another note")
      let window = host(session)
      defer { window.isHidden = true }
      let interaction = try #require(session.textView.findInteraction)
      interaction.presentFindNavigator(showingReplace: true)
      defer { interaction.dismissFindNavigator() }
      try await Task.sleep(for: .milliseconds(150))
      #expect(interaction.isFindNavigatorVisible)
      let find = try #require(interaction.activeFindSession)
      #expect(find.supportsReplacement)
      find.performSearch(query: "note", options: nil)
      #expect(find.resultCount == 2)
      find.replaceAll(searchQuery: "note", replacementString: "https://example.com", options: nil)
      session.textViewDidChange(session.textView)
      #expect(session.text == "A https://example.com and another https://example.com")
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
