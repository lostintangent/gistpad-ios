#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import GistPadEditor

  extension HostedEditorTests {
    @MainActor
    struct EditorFocusTests {
      @Test func focusRequestPlacesCaretNowAndFocusesOnWindowAttachment() {
        let source = "# Today\n\n日本語 👩🏽‍💻"
        let editor = Editor(fileID: "new", text: source)
        let end = NSRange(location: source.utf16.count, length: 0)
        editor.requestFocusAtEnd()
        #expect(editor.textView.selectedRange == end)
        #expect(!editor.textView.isFirstResponder)
        let window = host(editor, focused: false)
        defer { window.isHidden = true }
        #expect(editor.textView.isFirstResponder)
        #expect(editor.isEditing)
        #expect(editor.textView.selectedRange == end)
        #expect(editor.text == source)
        #expect(editor.generation == 0)
        #expect(editor.inputError == nil)
      }

      @Test func focusRequestIsConsumedOnceAndKeepsSourceAndNativeUndo() throws {
        let editor = Editor(fileID: "one-shot", text: "note")
        editor.requestFocusAtEnd()
        let window = host(editor, focused: false)
        defer { window.isHidden = true }
        #expect(editor.textView.isFirstResponder)
        let undo = try #require(editor.textView.undoManager)
        undo.removeAllActions()
        try editor.apply(
          Edit(range: NSRange(location: 4, length: 0), expected: "", replacement: "!"),
          generation: 0)
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.requestFocusAtEnd()
        #expect(editor.textView.isFirstResponder)
        #expect(editor.textView.selectedRange == NSRange(location: 5, length: 0))
        #expect(editor.text == "note!")
        #expect(editor.generation == 1)
        #expect(undo.canUndo)
        undo.undo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "note")
        #expect(!undo.canUndo)

        editor.textView.resignFirstResponder()
        let beginning = NSRange(location: 0, length: 0)
        editor.textView.selectedRange = beginning
        editor.textView.removeFromSuperview()
        let root = try #require(window.rootViewController)
        root.view.addSubview(editor.textView)
        window.layoutIfNeeded()
        #expect(!editor.textView.isFirstResponder)
        #expect(editor.textView.selectedRange == beginning)
        #expect(editor.text == "note")
      }
    }
  }
#endif
