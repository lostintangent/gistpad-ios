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
    #expect(MarkdownFrontMatter.contentStart(in: source) == prefix.utf16.count)
  }
}

#if canImport(UIKit)
  import UIKit

  @Suite(.serialized)
  @MainActor
  struct FrontMatterLayoutTests {
    @Test func hiddenParagraphsOccupyNoSpaceAndSelectAllKeepsSourceBytes() throws {
      let prefix = "---\nedit:\n  commands:\n    update: Preserve all source bytes\n---\n\n\n"
      let body = "# Visible content\n\n- [ ] A thought 日本語"
      let session = DocumentSession(documentID: "frontmatter", text: prefix + body)
      let view = session.textView
      let root = UIViewController()
      root.view.addSubview(view)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = root
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      window.makeKeyAndVisible()
      defer {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
      }
      let manager = try #require(view.textLayoutManager)
      manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
      view.layoutIfNeeded()
      let position = try #require(
        view.position(from: view.beginningOfDocument, offset: prefix.utf16.count))
      let caret = view.caretRect(for: position)
      #expect(abs(caret.minY - view.textContainerInset.top) < 2)
      #expect(session.contentStart == prefix.utf16.count)
      #expect(session.selection == NSRange(location: prefix.utf16.count, length: 0))
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
      #expect(view.selectedRange == NSRange(location: (prefix + body).utf16.count, length: 0))
      session.requestFocusAtContentStart()
      #expect(view.isFirstResponder)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
      view.selectedTextRange = view.textRange(
        from: view.beginningOfDocument, to: view.beginningOfDocument)
      #expect(view.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
      view.deleteBackward()
      #expect(session.text.utf8.elementsEqual((prefix + body).utf8))
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
      #expect(view.text.utf8.elementsEqual((prefix + body).utf8))
      #expect(session.text.utf8.elementsEqual((prefix + body).utf8))
      #expect(session.generation == 0)
      #expect(view.undoManager?.canUndo != true)
      #expect(view.accessibilityValue == body)
    }

    @Test func editingAndNativeUndoKeepTheHiddenPrefixAndFullSourceCoordinates() throws {
      let prefix = "---\r\nkey: e\u{301} 👩🏽‍💻\r\n---\r\n\r\n"
      let body = "# A task\r\n- [ ] Clean up\r\n"
      let session = DocumentSession(documentID: "frontmatter-edits", text: prefix + body)
      let view = session.textView
      let root = UIViewController()
      root.view.addSubview(view)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = root
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      window.makeKeyAndVisible()
      defer {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
      }
      try #require(view.becomeFirstResponder())
      let before = view.text ?? ""
      let range = (before as NSString).range(of: "[ ]")
      try session.apply(
        SourceMutation(range: range, expected: "[ ]", replacement: "[x]"),
        documentID: session.documentID, generation: 0)
      #expect(session.text == prefix + body.replacingOccurrences(of: "[ ]", with: "[x]"))
      try #require(view.undoManager?.canUndo == true)
      let editedGeneration = session.generation
      session.setShowsFrontMatter(true)
      session.setShowsFrontMatter(false)
      #expect(session.generation == editedGeneration)
      #expect(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(before.utf8))
      view.selectAll(nil)
      view.undoManager?.beginUndoGrouping()
      view.insertText("A replacement body")
      view.undoManager?.endUndoGrouping()
      #expect(session.text.utf8.elementsEqual((prefix + "A replacement body").utf8))
      #expect(view.accessibilityValue == "A replacement body")
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(before.utf8))
      #expect(view.text.utf8.elementsEqual(before.utf8))
      #expect(view.selectedRange.location >= prefix.utf16.count)
      let fullRange = NSRange(location: 0, length: before.utf16.count)
      let ignored = session.textView(view, writingToolsIgnoredRangesInEnclosingRange: fullRange)
        .map(\.rangeValue)
      #expect(ignored.contains(NSRange(location: 0, length: prefix.utf16.count)))
      #expect(zip(ignored, ignored.dropFirst()).allSatisfy { NSMaxRange($0) < $1.location })
    }

    @Test(arguments: ["---\nkey: value\n---\n", "---\nkey: value\n---\n\n  "])
    func anEmptyBodyRemainsARealTypingParagraph(source: String) throws {
      let session = DocumentSession(documentID: "frontmatter-empty", text: source)
      let view = session.textView
      let root = UIViewController()
      root.view.addSubview(view)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = root
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      window.makeKeyAndVisible()
      defer {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
      }
      try #require(view.becomeFirstResponder())
      let manager = try #require(view.textLayoutManager)
      manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
      view.layoutIfNeeded()
      let position = try #require(
        view.position(
          from: view.beginningOfDocument, offset: session.contentStart))
      #expect(abs(view.caretRect(for: position).minY - view.textContainerInset.top) < 2)
      let prefix = (source as NSString).substring(to: session.contentStart)
      view.selectAll(nil)
      view.undoManager?.beginUndoGrouping()
      view.insertText("A new thought")
      view.undoManager?.endUndoGrouping()
      #expect(session.text.utf8.elementsEqual((prefix + "A new thought").utf8))
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(view.selectedRange.location >= prefix.utf16.count)
    }

    @Test func fullSourceMutationsCanChangeHiddenMetadataAndUndoItWithoutMovingIntoThePrefix()
      throws
    {
      let prefix = "---\nkey: A longer value 👩🏽‍💻\n---\n\n"
      let body = "A retained thought"
      let source = prefix + body
      let session = DocumentSession(documentID: "frontmatter-mutation", text: source)
      let view = session.textView
      let root = UIViewController()
      root.view.addSubview(view)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = root
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      window.makeKeyAndVisible()
      defer {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
      }
      try #require(view.becomeFirstResponder())
      let range = (source as NSString).range(of: "A longer value 👩🏽‍💻")
      try session.apply(
        SourceMutation(range: range, expected: "A longer value 👩🏽‍💻", replacement: "Short"),
        documentID: session.documentID, generation: session.generation)
      let nextPrefix = "---\nkey: Short\n---\n\n"
      #expect(session.text.utf8.elementsEqual((nextPrefix + body).utf8))
      #expect(session.contentStart == nextPrefix.utf16.count)
      #expect(session.selection == NSRange(location: nextPrefix.utf16.count, length: 0))
      try #require(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.contentStart == prefix.utf16.count)
      #expect(session.selection == NSRange(location: prefix.utf16.count, length: 0))
    }

    @Test func showingMetadataWaitsForCompositionAndDoesNotChangeSourceGeneration() throws {
      let prefix = "---\nkey: value\n---\n\n"
      let session = DocumentSession(documentID: "frontmatter-composition", text: prefix + "Body")
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
      let session = DocumentSession(documentID: "frontmatter-replacement", text: source)
      let view = session.textView
      let root = UIViewController()
      root.view.addSubview(view)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = root
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      window.makeKeyAndVisible()
      defer {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
      }
      try #require(view.becomeFirstResponder())
      try session.apply(
        SourceMutation(
          range: NSRange(location: 0, length: source.utf16.count), expected: source,
          replacement: replacement),
        documentID: session.documentID, generation: session.generation)
      #expect(session.text.utf8.elementsEqual(replacement.utf8))
      #expect(session.contentStart == 0)
      #expect(view.selectedRange.location <= replacement.utf16.count)
      try #require(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.contentStart == prefix.utf16.count)
      #expect(session.selection == NSRange(location: prefix.utf16.count, length: 0))
    }

    @Test func visibilityChangesWaitForWritingToolsAndDoNotAddAnUndoStep() {
      let source = "---\nkey: value\n---\n\nBody"
      let session = DocumentSession(documentID: "frontmatter-writing-tools", text: source)
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
