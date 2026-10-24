import GistPadEditor
import Testing
import UIKit

extension EditorContinuityTests {
  @Test func completeWritingToolsUsesPlainSourceAndAbsoluteIgnoredRanges() {
    let source = "日本語 👩🏽‍💻 before ``a ` b`` after"
    let session = DocumentSession(documentID: "test", text: source)
    #expect(session.textView.writingToolsBehavior == .complete)
    #expect(session.textView.allowedWritingToolsResultOptions == .plainText)
    #expect(session.textView.bottomEdgeEffect.style == .soft)
    let enclosing = (source as NSString).range(of: "before ``a ` b`` after")
    let ignored = session.textView(
      session.textView, writingToolsIgnoredRangesInEnclosingRange: enclosing)
    #expect(ignored.map(\.rangeValue) == [(source as NSString).range(of: "``a ` b``")])
    Attachment.record(
      "UIWritingToolsCoordinator.isWritingToolsAvailable = \(UIWritingToolsCoordinator.isWritingToolsAvailable)",
      named: "writing-tools-system-availability.txt")
  }

  @Test func temporaryPreviewsCannotPersistOrAcceptExternalMutations() throws {
    let source = "Original 日本語 `source`"
    let session = DocumentSession(documentID: "test", text: source, generation: 7)
    var changes: [String] = []
    session.onSourceChange = { text, _ in changes.append(text) }
    session.textViewWritingToolsWillBegin(session.textView)
    for preview in ["First proposal", "Another proposal", source] {
      session.textView.text = preview
      session.textViewDidChange(session.textView)
      session.highlight()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 7)
      #expect(changes.isEmpty)
    }
    #expect(throws: SourceMutation.MutationError.compositionActive) {
      try session.apply(
        SourceMutation(
          range: NSRange(location: 0, length: 8), expected: "Original",
          replacement: "External"), documentID: "test", generation: 7)
    }
    session.textViewWritingToolsDidEnd(session.textView)
    #expect(!session.writingToolsActive)
    #expect(session.generation == 7)
    #expect(changes.isEmpty)
  }

  @Test func acceptedNativeReplacementIsOneUndoableEditAndSurvivesReflow() async throws {
    let source = "A rough sentence.\n日本語 👨‍👩‍👧‍👦 `protected`"
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer {
      session.textView.resignFirstResponder()
      window.isHidden = true
    }
    let identity = ObjectIdentifier(session.textView)
    session.textView.becomeFirstResponder()
    session.textView.selectedRange = (source as NSString).range(of: "rough")
    var changes: [String] = []
    session.onSourceChange = { text, _ in changes.append(text) }
    session.textViewWritingToolsWillBegin(session.textView)
    let selected = try #require(session.textView.selectedTextRange)
    session.textView.replace(selected, withText: "clearer")
    session.textViewDidChange(session.textView)
    let finalText = try #require(session.textView.text)
    let finalSelection = session.textView.selectedRange
    #expect(changes.isEmpty)
    for width in [952.0, 402.0] {
      session.textView.frame.size.width = width
      session.textView.layoutIfNeeded()
      session.highlight()
      #expect(session.textView.selectedRange == finalSelection)
      #expect(session.textView.text.utf8.elementsEqual(finalText.utf8))
      #expect(session.text.utf8.elementsEqual(source.utf8))
    }
    session.textViewWritingToolsDidEnd(session.textView)
    #expect(changes == [finalText])
    #expect(session.generation == 1)
    #expect(session.selection == finalSelection)
    try await Task.sleep(for: .milliseconds(150))
    for width in [952.0, 402.0, 700.0, 360.0] {
      session.textView.frame.size.width = width
      session.textView.layoutIfNeeded()
      session.highlight()
      #expect(ObjectIdentifier(session.textView) == identity)
      #expect(session.textView.selectedRange == finalSelection)
      #expect(session.text.utf8.elementsEqual(finalText.utf8))
    }
    #expect(session.textView.undoManager?.canUndo == true)
    session.textView.undoManager?.undo()
    #expect(session.textView.text.utf8.elementsEqual(source.utf8))
    #expect(session.text.utf8.elementsEqual(source.utf8))
    #expect(changes == [finalText, source])
    session.textView.undoManager?.redo()
    #expect(session.text.utf8.elementsEqual(finalText.utf8))
    #expect(session.selection == session.textView.selectedRange)
  }

  @Test(arguments: [false, true])
  func readingAnchorSurvivesWritingToolsCompletionAndSubsequentReflow(
    waitForDecoration: Bool
  ) async throws {
    let source = try EditorFixture.markdown()
    let session = DocumentSession(documentID: "test", text: source)
    let window = try host(session)
    defer { window.isHidden = true }
    let manager = try #require(session.textView.textLayoutManager)
    let documentRange = try #require(manager.textContentManager?.documentRange)
    manager.ensureLayout(for: documentRange)
    session.textView.scrollRangeToVisible(NSRange(location: source.utf16.count / 2, length: 0))
    try await Task.sleep(for: .milliseconds(150))
    session.textViewWritingToolsWillBegin(session.textView)
    session.textViewWritingToolsDidEnd(session.textView)
    session.textView.layoutIfNeeded()
    let point = CGPoint(
      x: session.textView.textContainerInset.left,
      y: session.textView.contentOffset.y + session.textView.adjustedContentInset.top + 1)
    let position = try #require(session.textView.closestPosition(to: point))
    let offset = session.textView.offset(from: session.textView.beginningOfDocument, to: position)
    try #require(offset > 0)
    let originalY =
      session.textView.caretRect(for: position).minY - session.textView.contentOffset.y
    let identity = ObjectIdentifier(session.textView)
    let selection = session.textView.selectedRange
    if waitForDecoration {
      try await Task.sleep(for: .milliseconds(150))
      let decorated = try #require(
        session.textView.position(from: session.textView.beginningOfDocument, offset: offset))
      #expect(
        abs(session.textView.caretRect(for: decorated).minY
          - session.textView.contentOffset.y - originalY)
          <= session.textView.caretRect(for: decorated).height,
        "The deferred Writing Tools decoration must preserve the completed reading position.")
    }
    for width in [900.0, 360.0, 700.0, 402.0] {
      session.textView.frame.size.width = width
      session.textView.layoutIfNeeded()
      session.highlight()
      try await Task.sleep(for: .milliseconds(150))
      let restored = try #require(
        session.textView.position(from: session.textView.beginningOfDocument, offset: offset))
      let caret = session.textView.caretRect(for: restored)
      let nextLine = try #require(session.textView.position(from: restored, in: .down, offset: 1))
      let lineHeight = session.textView.caretRect(for: nextLine).minY - caret.minY
      try #require(lineHeight > 0)
      let scale = session.textView.traitCollection.displayScale
      let drift = abs(caret.minY - session.textView.contentOffset.y - originalY)
      #expect(
        (drift * scale).rounded() <= (lineHeight * scale).rounded(),
        "Width \(width), anchor \(offset), original Y \(originalY), current Y \(caret.minY - session.textView.contentOffset.y)")
      #expect(ObjectIdentifier(session.textView) == identity)
      #expect(session.textView.selectedRange == selection)
      #expect(session.generation == 0)
      #expect(session.text.utf8.elementsEqual(source.utf8))
    }
  }
}
