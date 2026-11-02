@testable import GistPadEditor
import Testing
import UIKit

@testable import GistPad

extension EditorContinuityTests {
  @Test func completeWritingToolsUsesPlainSourceAndAbsoluteIgnoredRanges() {
    let source = "日本語 👩🏽‍💻 before ``a ` b`` after"
    let session = Editor(fileID: "test", text: source)
    #expect(session.textView.writingToolsBehavior == .complete)
    #expect(session.textView.allowedWritingToolsResultOptions == .plainText)
    let enclosing = (source as NSString).range(of: "before ``a ` b`` after")
    let ignored = session.textView(
      session.textView, writingToolsIgnoredRangesInEnclosingRange: enclosing)
    #expect(ignored.map(\.rangeValue) == [(source as NSString).range(of: "``a ` b``")])
  }

  @Test func temporaryPreviewsCannotPersistOrAcceptExternalMutations() throws {
    let source = "Original 日本語 `source`"
    let session = Editor(fileID: "test", text: source, generation: 7)
    var changes: [String] = []
    session.onEdit = { text, _ in changes.append(text) }
    session.textViewWritingToolsWillBegin(session.textView)
    for preview in ["First proposal", "Another proposal", source] {
      session.textView.text = preview
      session.textViewDidChange(session.textView)
      session.highlight()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 7)
      #expect(changes.isEmpty)
    }
    #expect(throws: Edit.MutationError.compositionActive) {
      try session.apply(
        Edit(
          range: NSRange(location: 0, length: 8), expected: "Original", replacement: "External"),
        generation: 7)
    }
    session.textViewWritingToolsDidEnd(session.textView)
    #expect(!session.isWritingToolsActive)
    #expect(session.generation == 7)
    #expect(changes.isEmpty)
  }

  @Test func acceptedNativeReplacementIsOneUndoableEditAndSurvivesReflow() async throws {
    let source = "A rough sentence.\n日本語 👨‍👩‍👧‍👦 `protected`"
    let session = Editor(fileID: "test", text: source)
    let window = try host(session)
    defer {
      session.textView.resignFirstResponder()
      window.isHidden = true
    }
    session.textView.becomeFirstResponder()
    session.textView.selectedRange = (source as NSString).range(of: "rough")
    var changes: [String] = []
    session.onEdit = { text, _ in changes.append(text) }
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
    #expect(session.textView.selectedRange == finalSelection)
    try await Task.sleep(for: .milliseconds(150))
    for width in [952.0, 402.0, 700.0, 360.0] {
      session.textView.frame.size.width = width
      session.textView.layoutIfNeeded()
      session.highlight()
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
  }
}
