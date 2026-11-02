import GistPadEditor
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
    let mutation = SourceMutation(
      range: (source as NSString).range(of: "[ ]", options: .backwards), expected: "[ ]",
      replacement: "[x]")
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

  @Test func previewMutationDoesNotNeedKeyboardAndPreservesSelection() throws {
    let source = "👨‍👩‍👧‍👦\n- [ ] Duplicate\n- [ ] Duplicate\n日本語"
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer { window.isHidden = true }
    session.textView.selectedRange = NSRange(location: 0, length: 0)
    let mutation = SourceMutation(
      range: (source as NSString).range(of: "[ ]", options: .backwards),
      expected: "[ ]", replacement: "[x]")
    try session.apply(mutation, documentID: "test", generation: 0)
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

  @Test func readingAnchorSurvivesReflowAndAppearanceRestyling() async throws {
    let source = try EditorFixture.markdown()
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer { window.isHidden = true }
    session.textView.resignFirstResponder()
    try await Task.sleep(for: .milliseconds(150))
    let manager = try #require(session.textView.textLayoutManager)
    let documentRange = try #require(manager.textContentManager?.documentRange)
    manager.ensureLayout(for: documentRange)
    session.textView.scrollRangeToVisible(
      NSRange(location: source.utf16.count / 2, length: 0))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while session.textView.contentOffset.y <= 0, ContinuousClock.now < deadline {
      session.textView.scrollRangeToVisible(
        NSRange(location: source.utf16.count / 2, length: 0))
      try await Task.sleep(for: .milliseconds(20))
      session.textView.layoutIfNeeded()
    }
    try #require(
      session.textView.contentOffset.y > 0,
      "The reading-anchor fixture must scroll to its middle source range before measuring.")
    session.textView.layoutIfNeeded()
    let point = CGPoint(
      x: session.textView.textContainerInset.left,
      y: session.textView.contentOffset.y + session.textView.adjustedContentInset.top + 1)
    let position = try #require(session.textView.closestPosition(to: point))
    let offset = session.textView.offset(
      from: session.textView.beginningOfDocument, to: position)
    try #require(offset > 0)
    let originalY =
      session.textView.caretRect(for: position).minY - session.textView.contentOffset.y
    for width in [900.0, 360.0, 700.0, 402.0] {
      session.textView.frame.size.width = width
      session.textView.layoutIfNeeded()
      session.highlight()
      try await Task.sleep(for: .milliseconds(150))
      let restored = try #require(
        session.textView.position(from: session.textView.beginningOfDocument, offset: offset))
      let caret = session.textView.caretRect(for: restored)
      let currentY = caret.minY - session.textView.contentOffset.y
      let nextLine = try #require(session.textView.position(from: restored, in: .down, offset: 1))
      let lineHeight = session.textView.caretRect(for: nextLine).minY - caret.minY
      try #require(lineHeight > 0)
      #expect(
        abs(currentY - originalY) <= lineHeight,
        "Width \(width), anchor \(offset), original Y \(originalY), current Y \(currentY)")
      #expect(session.textView.text == source)
    }
  }
}
