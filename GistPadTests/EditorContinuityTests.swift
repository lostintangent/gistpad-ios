@testable import GistPadEditor
import SwiftUI
import Testing
import UIKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct EditorContinuityTests {
  func host(_ session: DocumentSession) throws -> UIWindow {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
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
    let source = EditorFixture.markdown
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer { window.isHidden = true }
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
    let edit = SourceEdit(
      range: (source as NSString).range(of: "[ ]", options: .backwards), expected: "[ ]",
      replacement: "[x]")
    try session.apply(edit, generation: 0)
    #expect(session.text == "- [ ] Duplicate\n- [x] Duplicate")
    #expect(throws: SourceEdit.MutationError.staleGeneration) {
      try session.apply(edit, generation: 0)
    }
    session.textView.undoManager?.undo()
    #expect(session.textView.text == source)
    session.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
    #expect(throws: SourceEdit.MutationError.compositionActive) {
      try session.apply(edit, generation: session.generation)
    }
  }

  @Test func previewMutationDoesNotNeedKeyboardAndPreservesSelection() throws {
    let source = "👨‍👩‍👧‍👦\n- [ ] Duplicate\n- [ ] Duplicate\n日本語"
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer { window.isHidden = true }
    session.textView.selectedRange = NSRange(location: 0, length: 0)
    try session.apply(
      SourceEdit(
        range: (source as NSString).range(of: "[ ]", options: .backwards),
        expected: "[ ]", replacement: "[x]"),
      generation: 0)
    #expect(!session.textView.isFirstResponder)
    #expect(session.textView.selectedRange == NSRange(location: 0, length: 0))
    #expect(session.textView.undoManager?.canUndo == true)
    session.textView.undoManager?.undo()
    #expect(session.textView.text == source)
  }

  @Test func normalizationOnlyEditsAdvanceTheSourceGeneration() {
    let session = DocumentSession(documentID: "unicode", text: "cafe\u{301}")
    session.textView.text = "caf\u{e9}"
    session.textViewDidChange(session.textView)
    #expect(session.generation == 1)
    #expect(session.text.utf8.elementsEqual("caf\u{e9}".utf8))
  }

  @Test(arguments: [(false, false), (true, false), (true, true)])
  func readingAnchorSurvivesReflowAndWritingToolsCompletion(
    writingTools: Bool, waitForDecoration: Bool
  ) async throws {
    let source = EditorFixture.markdown
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer { window.isHidden = true }
    let view = session.textView
    let manager = try #require(view.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let middle = NSRange(location: source.utf16.count / 2, length: 0)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while view.contentOffset.y <= 0, ContinuousClock.now < deadline {
      view.scrollRangeToVisible(middle)
      try await Task.sleep(for: .milliseconds(20))
      view.layoutIfNeeded()
    }
    try #require(
      view.contentOffset.y > 0,
      "The reading-anchor fixture must scroll to its middle source range before measuring.")
    if writingTools {
      session.textViewWritingToolsWillBegin(view)
      session.textViewWritingToolsDidEnd(view)
    }
    view.layoutIfNeeded()
    let point = CGPoint(
      x: view.textContainerInset.left,
      y: view.contentOffset.y + view.adjustedContentInset.top + 1)
    let position = try #require(view.closestPosition(to: point))
    let offset = view.offset(from: view.beginningOfDocument, to: position)
    try #require(offset > 0)
    let originalY = view.caretRect(for: position).minY - view.contentOffset.y
    let selection = view.selectedRange
    if waitForDecoration {
      try await Task.sleep(for: .milliseconds(150))
      let decorated = try #require(view.position(from: view.beginningOfDocument, offset: offset))
      #expect(
        abs(view.caretRect(for: decorated).minY - view.contentOffset.y - originalY)
          <= view.caretRect(for: decorated).height,
        "The deferred Writing Tools decoration must preserve the completed reading position.")
    }
    for width in [900.0, 360.0, 700.0, 402.0] {
      view.frame.size.width = width
      view.layoutIfNeeded()
      session.highlight()
      try await Task.sleep(for: .milliseconds(150))
      let restored = try #require(view.position(from: view.beginningOfDocument, offset: offset))
      let caret = view.caretRect(for: restored)
      let nextLine = try #require(view.position(from: restored, in: .down, offset: 1))
      let lineHeight = view.caretRect(for: nextLine).minY - caret.minY
      try #require(lineHeight > 0)
      let scale = view.traitCollection.displayScale
      let currentY = caret.minY - view.contentOffset.y
      #expect(
        (abs(currentY - originalY) * scale).rounded() <= (lineHeight * scale).rounded(),
        "Width \(width), anchor \(offset), original Y \(originalY), current Y \(currentY)")
      #expect(view.selectedRange == selection)
      #expect(session.generation == 0)
      #expect(session.text.utf8.elementsEqual(source.utf8))
    }
  }
}
