#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import Editor

  extension HostedEditorTests {
    @MainActor
    struct EditorFocusTests {
      @Test func focusRequestPlacesCaretNowAndFocusesOnWindowAttachment() {
        let source = "# Today\n\n日本語 👩🏽‍💻"
        let editor = Editor(text: source)
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

      @Test func beginningToEditLeavesTheReadingPositionForTheTappedCaret() throws {
        let source = (1...200).map { "Line \($0)" }.joined(separator: "\n")
        let editor = Editor(text: source)
        let window = host(editor, focused: false)
        defer { window.isHidden = true }
        let view = editor.textView
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
        view.selectedRange = NSRange(location: source.utf16.count, length: 0)
        view.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        view.layoutIfNeeded()
        // UIKit begins editing before it places a tap's caret, so the old caret must not scroll.
        try #require(view.becomeFirstResponder())
        #expect(editor.isEditing)
        #expect(abs(view.contentOffset.y - 1200) < 1)
      }

      @Test func revealingTheEndOfALongNoteShowsTheCaret() throws {
        let source = (1...400).map { n in
          """
          ## Section \(n)

          A paragraph long enough to wrap across several lines of a phone-width column, so \
          TextKit's estimate for text it hasn't laid out drifts from the laid-out height.

          - [ ] A task
          - Another item with `code`

          ```swift
          let value = \(n)
          ```
          """
        }.joined(separator: "\n\n")
        let editor = Editor(text: source)
        let window = host(editor)
        defer { window.isHidden = true }
        let view = editor.textView
        let manager = try #require(view.textLayoutManager)
        let exact = view.contentSize.height
        // Restyling outside an anchored update leaves TextKit's short estimate for offscreen text.
        manager.invalidateLayout(for: try #require(manager.textContentManager?.documentRange))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try #require(view.contentSize.height < exact)
        view.selectedRange = NSRange(location: source.utf16.count, length: 0)
        view.scrollRangeToVisible(view.selectedRange)
        view.layoutIfNeeded()
        let caret = view.caretRect(for: try #require(view.selectedTextRange?.end))
        #expect(view.bounds.inset(by: view.adjustedContentInset).contains(caret))
      }

      @Test func focusRequestIsConsumedOnceAndKeepsSourceAndNativeUndo() throws {
        let editor = Editor(text: "note")
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

      @Test func aLandingTapTreatsEveryPositionAsAWordEdge() throws {
        let view = Editor(text: "Uncharacteristically").textView
        let middle = try #require(view.position(from: view.beginningOfDocument, offset: 6))
        // Whether the position is inside a word, and whether it's a word's edge.
        func answers() -> [Bool] {
          [
            view.tokenizer.isPosition(middle, withinTextUnit: .word, inDirection: .storage(.forward)),
            view.tokenizer.isPosition(middle, atBoundary: .word, inDirection: .storage(.backward)),
          ]
        }
        #expect(answers() == [true, false])

        view.isLandingTap = true
        #expect(answers() == [false, true])
        // The word itself stays whole, so a tap on a misspelling still selects it.
        let word = try #require(
          view.tokenizer.rangeEnclosingPosition(middle, with: .word, inDirection: .storage(.forward)))
        #expect(view.offset(from: word.start, to: word.end) == 20)

        view.isLandingTap = false
        #expect(answers() == [true, false])
      }
    }
  }
#endif
