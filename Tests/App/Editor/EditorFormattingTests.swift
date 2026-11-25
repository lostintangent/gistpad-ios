import Markdown
import Testing
import UIKit

@testable import Editor

@Suite(.serialized, .timeLimit(.minutes(1)))
struct EditorFormattingTests {
    @Test func formattingIsOneNativeUndoWithFinalSelection() throws {
        let editor = MarkdownEditor(text: "A 日本語 note")
        let window = try hostEditor(editor)
        defer { window.isHidden = true }
        let originalSelection = (editor.text as NSString).range(of: "日本語")
        editor.textView.selectedRange = originalSelection
        editor.textView.undoManager?.removeAllActions()
        var savedSelection: NSRange?
        var changes = 0
        editor.onEdit = { _, _ in
            savedSelection = editor.textView.selectedRange
            changes += 1
        }
        let edit = MarkdownDocument(editor.text).edit(bolding: originalSelection)
        try editor.apply(edit, generation: 0)
        #expect(editor.text == "A **日本語** note")
        #expect(editor.textView.selectedRange == edit.selection)
        #expect(savedSelection == edit.selection)
        #expect(changes == 1)
        #expect(editor.generation == 1)
        editor.textView.undoManager?.undo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "A 日本語 note")
        #expect(editor.textView.selectedRange == originalSelection)
        #expect(editor.textView.undoManager?.canUndo == false)
        editor.textView.undoManager?.redo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "A **日本語** note")
    }

    @Test func staleLinkNeverChangesSource() throws {
        let editor = MarkdownEditor(text: "note")
        let edit = try MarkdownDocument(editor.text).edit(
            linking: NSRange(location: 0, length: 4), to: "https://example.com", label: "note")
        #expect(throws: MarkdownEdit.Failure.changed) {
            try editor.apply(edit, generation: 1)
        }
        #expect(editor.text == "note")
        #expect(editor.generation == 0)
    }

    @Test func compositionWritingToolsAndReadOnlyBlockFormatting() throws {
        let editor = MarkdownEditor(text: "note")
        let window = try hostEditor(editor)
        defer { window.isHidden = true }
        let edit = MarkdownDocument(editor.text).edit(bolding: NSRange(location: 0, length: 4))
        editor.textViewWritingToolsWillBegin(editor.textView)
        editor.find()
        #expect(editor.inputError != nil)
        #expect(editor.textView.findInteraction?.isFindNavigatorVisible == false)
        editor.inputError = nil
        #expect(throws: MarkdownEdit.Failure.unsettled) {
            try editor.apply(edit, generation: 0)
        }
        editor.textViewWritingToolsDidEnd(editor.textView)
        editor.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        #expect(!editor.canFormat)
        editor.find()
        #expect(editor.inputError != nil)
        #expect(editor.textView.findInteraction?.isFindNavigatorVisible == false)
        #expect(throws: MarkdownEdit.Failure.unsettled) {
            try editor.apply(edit, generation: 0)
        }
        editor.textView.unmarkText()
        editor.textViewDidChange(editor.textView)
        editor.textView.isEditable = false
        #expect(!editor.canFormat)
    }

    @Test func smartTypingYieldsToCompositionWritingToolsAndProtectedSyntax() throws {
        for source in ["```\n- code", "---\n- metadata", "Ordinary prose"] {
            let editor = MarkdownEditor(text: source)
            let caret = NSRange(location: source.utf16.count, length: 0)
            #expect(
                editor.textView(
                    editor.textView, shouldChangeTextInRanges: [NSValue(range: caret)],
                    replacementText: "\n"))
            #expect(editor.text == source)
        }
        let editor = MarkdownEditor(text: "- note")
        let window = try hostEditor(editor)
        defer { window.isHidden = true }
        editor.textViewWritingToolsWillBegin(editor.textView)
        #expect(
            editor.textView(
                editor.textView,
                shouldChangeTextInRanges: [NSValue(range: NSRange(location: 6, length: 0))],
                replacementText: "\n"))
        editor.textViewWritingToolsDidEnd(editor.textView)
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        editor.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        let transient = editor.textView.text
        #expect(
            editor.textView(
                editor.textView,
                shouldChangeTextInRanges: [NSValue(range: editor.textView.selectedRange)],
                replacementText: "\n"))
        #expect(editor.textView.text == transient)
    }

    @Test func aBracketPairUndoesInOneStepAndSteppingOverAddsNone() throws {
        let editor = MarkdownEditor(text: "Vagabond ")
        let window = try host(editor)
        defer { window.isHidden = true }
        let view = editor.textView
        view.selectedRange = NSRange(location: 9, length: 0)
        view.undoManager?.removeAllActions()
        #expect(
            !editor.textView(
                view, shouldChangeTextInRanges: [NSValue(range: view.selectedRange)],
                replacementText: "("))
        #expect(editor.text == "Vagabond ()")
        #expect(view.selectedRange == NSRange(location: 10, length: 0))
        let generation = editor.generation
        #expect(
            !editor.textView(
                view, shouldChangeTextInRanges: [NSValue(range: view.selectedRange)],
                replacementText: ")"))
        #expect(editor.text == "Vagabond ()")
        #expect(editor.generation == generation)
        #expect(view.selectedRange == NSRange(location: 11, length: 0))
        view.undoManager?.undo()
        editor.textViewDidChange(view)
        #expect(editor.text == "Vagabond ")
        #expect(view.undoManager?.canUndo == false)
    }

    @Test func aURLTypedOverDiscontiguousSelectionsKeepsTheWordsBetween() throws {
        let editor = MarkdownEditor(text: "one keep two")
        let window = try host(editor)
        defer { window.isHidden = true }
        let view = editor.textView
        view.selectedRanges = [NSRange(location: 0, length: 3), NSRange(location: 9, length: 3)]
        view.insertText("https://example.test")
        #expect(["https://example.test keep ", " keep https://example.test"].contains(editor.text))
    }

    @Test func indentAndOutdentRetainSelectionAndNativeUndo() throws {
        let editor = MarkdownEditor(text: "- 日本語\n- next")
        let window = try hostEditor(editor)
        defer { window.isHidden = true }
        let original = editor.text
        editor.textView.selectedRange = NSRange(location: 0, length: original.utf16.count)
        editor.textView.undoManager?.removeAllActions()
        editor.indent(outdent: false)
        #expect(editor.text == "  - 日本語\n  - next")
        #expect(
            editor.textView.selectedRange == NSRange(location: 2, length: original.utf16.count + 2))
        editor.textView.undoManager?.undo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == original)
        #expect(editor.textView.undoManager?.canUndo == false)
    }

    @Test func swipeIndentsAListLineAndIgnoresProse() throws {
        let editor = MarkdownEditor(text: "- item\nplain")
        let window = try host(editor)
        defer { window.isHidden = true }
        let caret = NSRange(location: editor.text.utf16.count, length: 0)
        editor.textView.selectedRange = caret
        editor.textView.layoutIfNeeded()
        func point(at needle: String) throws -> CGPoint {
            let range = (editor.text as NSString).range(of: needle)
            let position = try #require(
                editor.textView.position(
                    from: editor.textView.beginningOfDocument, offset: range.location))
            let caret = editor.textView.caretRect(for: position)
            return CGPoint(x: caret.midX, y: caret.midY)
        }
        #expect(editor.indentSwipedLine(at: try point(at: "item"), outdent: false))
        #expect(editor.text == "  - item\nplain")
        #expect(editor.textView.selectedRange == NSRange(location: caret.location + 2, length: 0))
        let after = editor.text
        #expect(!editor.indentSwipedLine(at: try point(at: "plain"), outdent: false))
        #expect(editor.text == after)
        let swipe = try #require(
            editor.textView.gestureRecognizers?.compactMap { $0 as? UISwipeGestureRecognizer }.first)
        #expect(
            editor.textView.gestureRecognizer(
                swipe, shouldRequireFailureOf: UIScreenEdgePanGestureRecognizer()))
    }

    @Test func keyboardBarBoldEditsTheSessionAndImageNeedsAnAction() throws {
        let editor = MarkdownEditor(text: "A note")
        let window = try hostEditor(editor)
        defer { window.isHidden = true }
        let toolbar = try #require(editor.textView.inputAccessoryView as? KeyboardBar)
        let items = toolbar.buttons.arrangedSubviews.compactMap { $0 as? UIButton }
        let style = try #require(items.first { $0.accessibilityLabel == "Text Style" }?.menu)
        let bold = try #require(menuActions(style.children).first { $0.title == "Bold" })
        editor.textView.selectedRange = NSRange(location: 2, length: 4)
        editor.textView.undoManager?.removeAllActions()
        let dispatch = UIButton(type: .system)
        dispatch.addAction(bold, for: .primaryActionTriggered)
        dispatch.sendActions(for: .primaryActionTriggered)
        #expect(editor.text == "A **note**")
        #expect(editor.generation == 1)
        editor.textView.undoManager?.undo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "A note")
        #expect(editor.textView.undoManager?.canUndo == false)
        let insert = try #require(
            items.first { $0.accessibilityIdentifier == "editor-insert-menu" }?.menu)
        let image = try #require(menuActions(insert.children).first { $0.title == "Image" })
        #expect(image.attributes.contains(.disabled))
        #expect(image.subtitle == nil)
    }

    @Test func voiceOverNamesTheTextViewByTheScreensTitle() throws {
        let editor = MarkdownEditor(text: "A note")
        let window = try hostEditor(editor, title: "Saturday walk")
        defer { window.isHidden = true }
        #expect(editor.textView.accessibilityLabel == "Saturday walk")
    }

    @Test func intelligenceAccessoryInvokesItsCallbackWithoutChangingSource() throws {
        let editor = MarkdownEditor(text: "A note")
        var requests = 0
        let window = try hostEditor(editor, intelligence: { requests += 1 })
        defer { window.isHidden = true }
        editor.textView.undoManager?.removeAllActions()
        let toolbar = try #require(editor.textView.inputAccessoryView as? KeyboardBar)
        let button = try #require(
            toolbar.buttons.arrangedSubviews.compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "editor-intelligence"
            })
        #expect(button.isEnabled)
        button.sendActions(for: .primaryActionTriggered)
        #expect(requests == 1)
        #expect(editor.text == "A note")
        #expect(editor.generation == 0)
        #expect(editor.textView.undoManager?.canUndo == false)
    }

    @Test func nativeFindAndReplaceKeepsURLReplacementsLiteral() throws {
        let editor = MarkdownEditor(text: "A note and another note")
        let window = try hostEditor(editor)
        defer { window.isHidden = true }
        let interaction = try #require(editor.textView.findInteraction)
        editor.find(replacing: true)
        defer { interaction.dismissFindNavigator() }
        #expect(interaction.isFindNavigatorVisible)
        let find = try #require(interaction.activeFindSession)
        #expect(find.supportsReplacement)
        find.performSearch(query: "note", options: nil)
        #expect(find.resultCount == 2)
        find.replaceAll(searchQuery: "note", replacementString: "https://example.com", options: nil)
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "A https://example.com and another https://example.com")
    }

    private func menuActions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return menuActions(menu.children) }
            return []
        }
    }
}
