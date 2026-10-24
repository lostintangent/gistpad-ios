import GistPadEditor
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct EditorContinuityTests {
    private func host(_ session: DocumentSession) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.addSubview(session.textView)
        session.textView.frame = controller.view.bounds
        session.textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    @Test func sameTextViewSelectionAndUndoSurviveRepeatedResize() throws {
        let source = try EditorFixture.markdown()
        let session = DocumentSession(documentID: "test", text: source)
        let window = try host(session)
        defer { window.isHidden = true }
        let identity = ObjectIdentifier(session.textView)
        #expect(session.textView.textLayoutManager != nil)
        session.textView.becomeFirstResponder()
        session.textView.selectedRange = NSRange(location: 8, length: 0)
        session.textView.undoManager?.beginUndoGrouping()
        session.textView.insertText("📝日本語")
        session.textView.undoManager?.endUndoGrouping()
        let edited = session.textView.text
        let selection = session.textView.selectedRange
        for width in [952.0, 402.0, 800.0, 360.0, 952.0] {
            session.textView.frame.size.width = width
            session.textView.layoutIfNeeded()
            session.highlight()
            #expect(ObjectIdentifier(session.textView) == identity)
            #expect(session.textView.text == edited)
            #expect(session.textView.selectedRange == selection)
        }
        session.textView.undoManager?.undo()
        #expect(session.textView.text == source)
    }

    @Test func programmaticMarkedTextSurvivesResizeWithoutHighlighting() throws {
        let session = DocumentSession(documentID: "test", text: "日本語のノート\n👨‍👩‍👧‍👦")
        let window = try host(session)
        defer { window.isHidden = true }
        session.textView.becomeFirstResponder()
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
        #expect(session.textView.markedTextRange != nil)
        let composing = session.textView.text
        for width in [952.0, 402.0, 952.0] {
            session.textView.frame.size.width = width
            session.textView.layoutIfNeeded()
            session.highlight()
            #expect(session.textView.text == composing)
            #expect(session.textView.markedTextRange != nil)
        }
        session.textView.unmarkText()
        session.highlight()
        #expect(session.textView.text == composing)
    }

    @Test func validatedMutationIsUndoableAndRejectsStaleOrComposingEdits() throws {
        let source = "- [ ] Duplicate\n- [ ] Duplicate"
        let session = DocumentSession(documentID: "test", text: source)
        let window = try host(session)
        defer { window.isHidden = true }
        session.textView.becomeFirstResponder()
        let mutation = SourceMutation(range: (source as NSString).range(of: "[ ]", options: .backwards), expected: "[ ]", replacement: "[x]")
        try session.apply(mutation, documentID: "test", generation: 0)
        #expect(session.text == "- [ ] Duplicate\n- [x] Duplicate")
        #expect(throws: SourceMutation.MutationError.staleGeneration) {
            try session.apply(mutation, documentID: "test", generation: 0)
        }
        session.textView.undoManager?.undo()
        #expect(session.textView.text == source)
        session.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        #expect(throws: SourceMutation.MutationError.compositionActive) {
            try session.apply(mutation, documentID: "test", generation: session.generation)
        }
    }

    @Test func rehostingSameViewPreservesMarkedTextAndIdentity() throws {
        let session = DocumentSession(documentID: "test", text: "日本語 👨‍👩‍👧‍👦")
        let window = try host(session)
        defer { window.isHidden = true }
        session.textView.becomeFirstResponder()
        session.textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        let text = session.textView.text
        let identity = ObjectIdentifier(session.textView)
        let newContainer = UIView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        window.rootViewController?.view.addSubview(newContainer)
        newContainer.addSubview(session.textView)
        session.textView.frame = newContainer.bounds
        newContainer.layoutIfNeeded()
        #expect(ObjectIdentifier(session.textView) == identity)
        #expect(session.textView.text == text)
        #expect(session.textView.markedTextRange != nil)
    }
}
