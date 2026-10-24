#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct DocumentFocusTests {
    @Test func focusRequestPlacesCaretNowAndFocusesOnWindowAttachment() {
      let source = "# Today\n\n日本語 👩🏽‍💻"
      let session = DocumentSession(documentID: "new", text: source)
      let end = NSRange(location: source.utf16.count, length: 0)
      session.requestFocusAtEnd()
      #expect(session.selection == end)
      #expect(session.textView.selectedRange == end)
      #expect(!session.textView.isFirstResponder)
      let window = host(session)
      defer { window.isHidden = true }
      #expect(session.textView.isFirstResponder)
      #expect(session.isEditing)
      #expect(session.textView.selectedRange == end)
      #expect(session.text == source)
      #expect(session.generation == 0)
      #expect(session.inputError == nil)
    }

    @Test func attachedFocusRequestPreservesSourceGenerationAndNativeUndo() throws {
      let session = DocumentSession(documentID: "attached", text: "note")
      let window = host(session)
      defer { window.isHidden = true }
      session.textView.becomeFirstResponder()
      let undo = try #require(session.textView.undoManager)
      undo.removeAllActions()
      try session.apply(
        SourceMutation(range: NSRange(location: 4, length: 0), expected: "", replacement: "!"),
        documentID: session.documentID, generation: 0)
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
    }

    @Test func completedFocusRequestDoesNotStealFocusOnReattachment() throws {
      let session = DocumentSession(documentID: "one-shot", text: "note")
      session.requestFocusAtEnd()
      let window = host(session)
      defer { window.isHidden = true }
      #expect(session.textView.isFirstResponder)
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
      #expect(session.generation == 0)
    }

    private func host(_ session: DocumentSession) -> UIWindow {
      // Package logic tests have no connected UIWindowScene.
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      let controller = UIViewController()
      window.rootViewController = controller
      window.makeKeyAndVisible()
      session.textView.frame = controller.view.bounds
      session.textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      controller.view.addSubview(session.textView)
      window.layoutIfNeeded()
      return window
    }
  }
#endif
