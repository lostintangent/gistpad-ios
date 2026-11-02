#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct EditorFocusTests {
    @Test func focusRequestPlacesCaretNowAndFocusesOnWindowAttachment() {
      let source = "# Today\n\n日本語 👩🏽‍💻"
      let session = Editor(fileID: "new", text: source)
      let end = NSRange(location: source.utf16.count, length: 0)
      session.requestFocusAtEnd()
      #expect(session.textView.selectedRange == end)
      #expect(!session.textView.isFirstResponder)
      let window = host(session, focused: false)
      defer { window.isHidden = true }
      #expect(session.textView.isFirstResponder)
      #expect(session.isEditing)
      #expect(session.textView.selectedRange == end)
      #expect(session.text == source)
      #expect(session.generation == 0)
      #expect(session.inputError == nil)
    }

    @Test func focusRequestIsConsumedOnceAndKeepsSourceAndNativeUndo() throws {
      let session = Editor(fileID: "one-shot", text: "note")
      session.requestFocusAtEnd()
      let window = host(session, focused: false)
      defer { window.isHidden = true }
      #expect(session.textView.isFirstResponder)
      let undo = try #require(session.textView.undoManager)
      undo.removeAllActions()
      try session.apply(
        Edit(range: NSRange(location: 4, length: 0), expected: "", replacement: "!"),
        generation: 0)
      session.textView.selectedRange = NSRange(location: 0, length: 0)
      session.requestFocusAtEnd()
      #expect(session.textView.isFirstResponder)
      #expect(session.textView.selectedRange == NSRange(location: 5, length: 0))
      #expect(session.text == "note!")
      #expect(session.generation == 1)
      #expect(undo.canUndo)
      undo.undo()
      session.textViewDidChange(session.textView)
      #expect(session.text == "note")
      #expect(!undo.canUndo)

      session.textView.resignFirstResponder()
      let beginning = NSRange(location: 0, length: 0)
      session.textView.selectedRange = beginning
      session.textView.removeFromSuperview()
      let root = try #require(window.rootViewController)
      root.view.addSubview(session.textView)
      window.layoutIfNeeded()
      #expect(!session.textView.isFirstResponder)
      #expect(session.textView.selectedRange == beginning)
      #expect(session.text == "note")
    }
  }
#endif
