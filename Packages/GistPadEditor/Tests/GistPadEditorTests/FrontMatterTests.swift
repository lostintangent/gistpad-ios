import Foundation
import Testing

@testable import GistPadEditor

struct FrontMatterRangeTests {
  @Test(arguments: [
    ("---\nkey: value\n---\n\n\n# Body", "---\nkey: value\n---\n\n\n"),
    ("--- \r\nkey: 日本語 👩🏽‍💻\r\n---\t\r\n \t\r\nBody", "--- \r\nkey: 日本語 👩🏽‍💻\r\n---\t\r\n \t\r\n"),
    ("---\nkey: value\n---\n", "---\nkey: value\n---\n"),
    ("---\nkey: value\n---\n\n  ", "---\nkey: value\n---\n\n"),
    ("---\nkey: value\n---", ""),
    ("---\nkey: value", ""),
    ("# Body\n---\nkey: value\n---\n", ""),
    (" ---\nkey: value\n---\nBody", ""),
    ("---\nkey: value\n...\nBody", ""),
    ("", ""),
  ])
  func hiddenPrefixMatchesTheWebBoundary(source: String, prefix: String) {
    #expect(FrontMatter.contentStart(in: source) == prefix.utf16.count)
  }
}

#if canImport(UIKit)
  import UIKit

  @Suite(.serialized)
  @MainActor
  struct FrontMatterLayoutTests {
    @Test(arguments: [
      "---\nedit:\n  commands:\n    update: Preserve all source bytes\n---\n\n\n",
      "---\r\nkey: e\u{301} 👩🏽‍💻\r\n---\r\n\r\n",
    ])
    func hiddenPrefixOccupiesNoSpaceAndKeepsSourceBytesThroughEditsAndUndo(prefix: String) throws {
      let body = "# Visible content\n\n- [ ] A thought 日本語"
      let source = prefix + body
      let session = Editor(fileID: "frontmatter", text: source)
      let view = session.textView
      let window = host(session, focused: false)
      defer { window.isHidden = true }
      let manager = try #require(view.textLayoutManager)
      manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
      view.layoutIfNeeded()
      let position = try #require(
        view.position(from: view.beginningOfDocument, offset: prefix.utf16.count))
      let caret = view.caretRect(for: position)
      #expect(abs(caret.minY - view.textContainerInset.top) < 2)
      #expect(session.contentStart == prefix.utf16.count)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
      view.selectAll(nil)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: body.utf16.count))
      #expect(
        !session.textView(
          view, shouldChangeTextIn: NSRange(location: prefix.utf16.count - 1, length: 1),
          replacementText: ""))
      view.selectedRange = NSRange(location: 0, length: 0)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
      try #require(view.becomeFirstResponder())
      session.requestFocusAtEnd()
      #expect(view.selectedRange == NSRange(location: source.utf16.count, length: 0))
      session.requestFocusAtContentStart()
      #expect(view.isFirstResponder)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
      view.selectedTextRange = view.textRange(
        from: view.beginningOfDocument, to: view.beginningOfDocument)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
      view.deleteBackward()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      session.setShowsFrontMatter(true)
      manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
      view.layoutIfNeeded()
      #expect(view.caretRect(for: position).minY > caret.minY + 80)
      #expect(session.contentStart == 0)
      session.setShowsFrontMatter(false)
      manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
      view.layoutIfNeeded()
      #expect(abs(view.caretRect(for: position).minY - caret.minY) < 2)
      #expect(view.text.utf8.elementsEqual(source.utf8))
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(view.undoManager?.canUndo != true)
      #expect(view.accessibilityValue == body)

      try session.apply(
        Edit(
          range: (source as NSString).range(of: "[ ]"), expected: "[ ]", replacement: "[x]"),
        generation: 0)
      #expect(session.text == prefix + body.replacingOccurrences(of: "[ ]", with: "[x]"))
      let edited = session.generation
      session.setShowsFrontMatter(true)
      session.setShowsFrontMatter(false)
      #expect(session.generation == edited)
      try #require(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      view.selectAll(nil)
      view.undoManager?.beginUndoGrouping()
      view.insertText("A replacement body")
      view.undoManager?.endUndoGrouping()
      #expect(session.text.utf8.elementsEqual((prefix + "A replacement body").utf8))
      #expect(view.accessibilityValue == "A replacement body")
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(view.selectedRange.location >= prefix.utf16.count)
      let ignored = session.textView(
        view, writingToolsIgnoredRangesInEnclosingRange: NSRange(
          location: 0, length: source.utf16.count)
      ).map(\.rangeValue)
      #expect(ignored.contains(NSRange(location: 0, length: prefix.utf16.count)))
      #expect(zip(ignored, ignored.dropFirst()).allSatisfy { NSMaxRange($0) < $1.location })
    }

    @Test func fullSourceMutationsCanChangeHiddenMetadataAndUndoItWithoutMovingIntoThePrefix()
      throws
    {
      let prefix = "---\nkey: A longer value 👩🏽‍💻\n---\n\n"
      let body = "A retained thought"
      let source = prefix + body
      let session = Editor(fileID: "frontmatter-mutation", text: source)
      let view = session.textView
      let window = host(session)
      defer { window.isHidden = true }
      try #require(view.isFirstResponder)
      let range = (source as NSString).range(of: "A longer value 👩🏽‍💻")
      try session.apply(
        Edit(range: range, expected: "A longer value 👩🏽‍💻", replacement: "Short"),
        generation: session.generation)
      let nextPrefix = "---\nkey: Short\n---\n\n"
      #expect(session.text.utf8.elementsEqual((nextPrefix + body).utf8))
      #expect(session.contentStart == nextPrefix.utf16.count)
      #expect(view.selectedRange == NSRange(location: nextPrefix.utf16.count, length: 0))
      try #require(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.contentStart == prefix.utf16.count)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
    }

    @Test func showingMetadataWaitsForCompositionAndDoesNotChangeSourceGeneration() throws {
      let prefix = "---\nkey: value\n---\n\n"
      let session = Editor(fileID: "frontmatter-composition", text: prefix + "Body")
      let view = session.textView
      view.selectedRange = NSRange(location: prefix.utf16.count, length: 0)
      view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
      session.textViewDidChange(view)
      try #require(view.markedTextRange != nil)
      let composingSelection = view.selectedRange
      session.requestFocusAtContentStart()
      #expect(view.selectedRange == composingSelection)
      #expect(view.markedTextRange != nil)
      #expect(session.inputError != nil)
      session.setShowsFrontMatter(true)
      #expect(!session.showsFrontMatter)
      #expect(session.contentStart == prefix.utf16.count)
      view.unmarkText()
      session.textViewDidChange(view)
      let generation = session.generation
      #expect(session.showsFrontMatter)
      #expect(session.contentStart == 0)
      #expect(session.text.hasPrefix(prefix))
      session.setShowsFrontMatter(false)
      #expect(session.generation == generation)
      #expect(session.contentStart == prefix.utf16.count)
    }

    @Test(arguments: ["A short body", ""])
    func replacingTheWholeSourceCanRemoveThePrefixAndUndoRestoresIt(replacement: String) throws {
      let prefix = "---\nkey: A longer metadata prefix\n---\n\n"
      let source = prefix + "A retained thought"
      let session = Editor(fileID: "frontmatter-replacement", text: source)
      let view = session.textView
      let window = host(session)
      defer { window.isHidden = true }
      try #require(view.isFirstResponder)
      try session.apply(
        Edit(
          range: NSRange(location: 0, length: source.utf16.count), expected: source,
          replacement: replacement),
        generation: session.generation)
      #expect(session.text.utf8.elementsEqual(replacement.utf8))
      #expect(session.contentStart == 0)
      #expect(view.selectedRange.location <= replacement.utf16.count)
      try #require(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.contentStart == prefix.utf16.count)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
    }

    @Test func visibilityChangesWaitForWritingToolsAndDoNotAddAnUndoStep() {
      let source = "---\nkey: value\n---\n\nBody"
      let session = Editor(fileID: "frontmatter-writing-tools", text: source)
      let view = session.textView
      session.textViewWritingToolsWillBegin(view)
      session.setShowsFrontMatter(true)
      #expect(!session.showsFrontMatter)
      session.textViewWritingToolsDidEnd(view)
      #expect(session.showsFrontMatter)
      #expect(session.contentStart == 0)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(view.undoManager?.canUndo != true)
    }
  }
#endif
