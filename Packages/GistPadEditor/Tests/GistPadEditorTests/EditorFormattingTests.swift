#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import GistPadEditor

  extension HostedEditorTests {
    @MainActor
    struct EditorFormattingTests {
      @Test func formattingIsOneNativeUndoWithFinalSelection() throws {
        let session = Editor(fileID: "format", text: "A 日本語 note")
        let window = hostEditor(session)
        defer { window.isHidden = true }
        let originalSelection = (session.text as NSString).range(of: "日本語")
        session.textView.selectedRange = originalSelection
        session.textView.undoManager?.removeAllActions()
        var savedSelection: NSRange?
        var changes = 0
        session.onEdit = { _, _ in
          savedSelection = session.textView.selectedRange
          changes += 1
        }
        let edit = try #require(
          try Formatting.edit(.bold, in: session.text, selection: originalSelection))
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
        let session = Editor(fileID: "link", text: "note")
        let edit = try #require(
          try Formatting.edit(
            .link(label: "note", destination: "https://example.com"),
            in: session.text, selection: NSRange(location: 0, length: 4)))
        #expect(throws: Edit.MutationError.staleGeneration) {
          try session.apply(edit, generation: 1)
        }
        let invalid = Edit(
          range: edit.range, expected: edit.expected, replacement: edit.replacement,
          selection: NSRange(location: 900, length: 0))
        #expect(throws: Edit.MutationError.invalidRange) {
          try session.apply(invalid, generation: 0)
        }
        #expect(session.text == "note")
        #expect(session.generation == 0)
      }

      @Test func compositionWritingToolsAndReadOnlyBlockFormatting() throws {
        let session = Editor(fileID: "blocked", text: "note")
        let window = hostEditor(session)
        defer { window.isHidden = true }
        let edit = try #require(
          try Formatting.edit(
            .bold, in: session.text, selection: NSRange(location: 0, length: 4)))
        session.textViewWritingToolsWillBegin(session.textView)
        session.find()
        #expect(session.inputError != nil)
        #expect(session.textView.findInteraction?.isFindNavigatorVisible == false)
        session.inputError = nil
        #expect(throws: Edit.MutationError.compositionActive) {
          try session.apply(edit, generation: 0)
        }
        session.textViewWritingToolsDidEnd(session.textView)
        session.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        #expect(!session.canFormat)
        session.find()
        #expect(session.inputError != nil)
        #expect(session.textView.findInteraction?.isFindNavigatorVisible == false)
        #expect(throws: Edit.MutationError.compositionActive) {
          try session.apply(edit, generation: 0)
        }
        session.textView.unmarkText()
        session.textViewDidChange(session.textView)
        session.textView.isEditable = false
        #expect(!session.canFormat)
      }

      @Test func smartTypingYieldsToCompositionWritingToolsAndProtectedSyntax() {
        for source in ["```\n- code", "---\n- metadata", "Ordinary prose"] {
          let session = Editor(fileID: "protected", text: source)
          let caret = NSRange(location: source.utf16.count, length: 0)
          #expect(
            session.textView(session.textView, shouldChangeTextIn: caret, replacementText: "\n"))
          #expect(session.text == source)
        }
        let session = Editor(fileID: "composing", text: "- note")
        let window = hostEditor(session)
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
        let session = Editor(fileID: "indent", text: "- 日本語\n- next")
        let window = hostEditor(session)
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

      @Test func keyboardBarBoldEditsTheSessionAndPhotoNeedsTheCapability() throws {
        let session = Editor(fileID: "accessory", text: "A note")
        let window = hostEditor(session, insertPhoto: {}, canInsertPhoto: false)
        defer { window.isHidden = true }
        let toolbar = try #require(session.textView.inputAccessoryView as? KeyboardBar)
        let items = toolbar.buttons.arrangedSubviews.compactMap { $0 as? UIButton }
        let style = try #require(items.first { $0.accessibilityLabel == "Text Style" }?.menu)
        let bold = try #require(menuActions(style.children).first { $0.title == "Bold" })
        session.textView.selectedRange = NSRange(location: 2, length: 4)
        session.textView.undoManager?.removeAllActions()
        let dispatch = UIButton(type: .system)
        dispatch.addAction(bold, for: .primaryActionTriggered)
        dispatch.sendActions(for: .primaryActionTriggered)
        #expect(session.text == "A **note**")
        #expect(session.generation == 1)
        session.textView.undoManager?.undo()
        session.textViewDidChange(session.textView)
        #expect(session.text == "A note")
        #expect(session.textView.undoManager?.canUndo == false)
        let insert = try #require(
          items.first { $0.accessibilityIdentifier == "editor-insert-menu" }?.menu)
        let photo = try #require(menuActions(insert.children).first { $0.title == "Photo" })
        #expect(photo.attributes.contains(.disabled))
      }

      @Test func intelligenceAccessoryInvokesItsCallbackWithoutChangingSource() throws {
        let session = Editor(fileID: "intelligence-button", text: "A note")
        var requests = 0
        let window = hostEditor(session, intelligence: { requests += 1 })
        defer { window.isHidden = true }
        session.textView.undoManager?.removeAllActions()
        let toolbar = try #require(session.textView.inputAccessoryView as? KeyboardBar)
        let button = try #require(
          toolbar.buttons.arrangedSubviews.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "editor-intelligence"
          })
        #expect(button.isEnabled)
        button.sendActions(for: .primaryActionTriggered)
        #expect(requests == 1)
        #expect(session.text == "A note")
        #expect(session.generation == 0)
        #expect(session.textView.undoManager?.canUndo == false)
      }

      @Test func nativeFindAndReplaceKeepsURLReplacementsLiteral() throws {
        let session = Editor(fileID: "find", text: "A note and another note")
        let window = hostEditor(session)
        defer { window.isHidden = true }
        let interaction = try #require(session.textView.findInteraction)
        session.find(replacing: true)
        defer { interaction.dismissFindNavigator() }
        #expect(interaction.isFindNavigatorVisible)
        let find = try #require(interaction.activeFindSession)
        #expect(find.supportsReplacement)
        find.performSearch(query: "note", options: nil)
        #expect(find.resultCount == 2)
        find.replaceAll(searchQuery: "note", replacementString: "https://example.com", options: nil)
        session.textViewDidChange(session.textView)
        #expect(session.text == "A https://example.com and another https://example.com")
      }

      private func menuActions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.flatMap { element -> [UIAction] in
          if let action = element as? UIAction { return [action] }
          if let menu = element as? UIMenu { return menuActions(menu.children) }
          return []
        }
      }
    }
  }
#endif
