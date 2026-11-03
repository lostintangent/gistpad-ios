#if canImport(UIKit)
  import Accessibility
  import Comments
  import Testing
  import UIKit
  @testable import Editor

  extension HostedEditorTests {
    @MainActor
    struct CommentHighlightTests {
      @Test func annotationsPreserveExactSourceGenerationSelectionAndNativeUndo() throws {
        let editor = Editor(fileID: "comments", text: "A native note", generation: 7)
        let window = host(editor)
        defer { window.isHidden = true }
        let undo = try #require(editor.textView.undoManager)
        undo.removeAllActions()
        try editor.apply(
          Edit(range: NSRange(location: 0, length: 1), expected: "A", replacement: "The"),
          generation: 7)
        editor.textView.selectedRange = NSRange(location: 4, length: 6)
        let selection = editor.textView.selectedRange
        var changes = 0
        editor.onEdit = { _, _ in changes += 1 }
        editor.setCommentHighlights(
          .init(
            quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        editor.highlight()
        #expect(editor.text == "The native note")
        #expect(editor.generation == 8)
        #expect(editor.textView.selectedRange == selection)
        #expect(changes == 0)
        #expect(editor.textView.textLayoutManager != nil)
        #expect(editor.textView.typingAttributes[.textHighlightStyle] == nil)
        #expect(editor.textView.typingAttributes[.textItemTag] == nil)
        undo.undo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "A native note")
        #expect(!undo.canUndo)
        undo.redo()
        editor.textViewDidChange(editor.textView)
        #expect(editor.text == "The native note")
      }

      @Test func overlapMenuKeepsSystemActionsAndOpensEveryThread() throws {
        let editor = Editor(fileID: "overlap", text: "one two three")
        var opened: [[Int64]] = []
        editor.setCommentHighlights(
          .init(quotes: [
            CommentQuote(commentID: 10, quote: "one two"),
            CommentQuote(commentID: 20, quote: "two three"),
          ]), onOpenCommentThreads: { opened.append($0) })
        #expect(
          editor.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) != nil)
        #expect(
          editor.textView.textStorage.attribute(.textHighlightStyle, at: 5, effectiveRange: nil)
            == nil)
        #expect(
          editor.textView.textStorage.attribute(
            .textItemTag, at: 5, effectiveRange: nil) == nil)
        let copy = UIAction(title: "System Copy") { _ in }
        let delegate: any UITextViewDelegate = editor
        let menu = try #require(
          delegate.textView?(
            editor.textView,
            editMenuForTextInRanges: [NSValue(range: NSRange(location: 4, length: 3))],
            suggestedActions: [copy]) ?? nil)
        #expect(menu.children.first === copy)
        let section = try #require(menu.children.last as? UIMenu)
        let action = try #require(section.children.first as? UIAction)
        #expect(action.title == "View Comment")
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(opened == [[10, 20]])
        #expect(editor.text == "one two three")
        #expect(editor.generation == 0)
      }

      @Test func passagesHitTestNativeGeometryAndAddCommentKeepsTheExactSelection() throws {
        let added = "  cafe\u{0301} 🫧\r\n"
        let source =
          "# Comment notebook\n\n🫧 A quiet native note, with **careful** words.\n" + added
        let editor = Editor(fileID: "hit-testing", text: source)
        let window = host(editor, focused: false)
        defer { window.isHidden = true }
        var quotes: [String] = []
        editor.setCommentHighlights(
          .init(quotes: [
            CommentQuote(commentID: 10, quote: "quiet native"),
            CommentQuote(commentID: 20, quote: "native note"),
          ]), onOpenCommentThreads: { _ in }, onAddComment: { quotes.append($0) })
        editor.textView.layoutIfNeeded()
        let range = (source as NSString).range(of: "native")
        let start = try #require(
          editor.textView.position(
            from: editor.textView.beginningOfDocument, offset: range.location))
        let end = try #require(editor.textView.position(from: start, offset: range.length))
        let frame = editor.textView.firstRect(
          for: try #require(editor.textView.textRange(from: start, to: end)))
        #expect(!frame.isEmpty)
        #expect(
          editor.commentHighlights.threadIDs(
            at: CGPoint(x: frame.midX, y: frame.midY)) == [10, 20],
          "Native frame \(frame), container inset \(editor.textView.textContainerInset)")

        let copy = UIAction(title: "System Copy") { _ in }
        let selection = editor.textView.selectedRange
        let addedRange = NSRange(
          location: source.utf16.count - added.utf16.count, length: added.utf16.count)
        let menu = try #require(
          editor.textView(
            editor.textView, editMenuForTextInRanges: [NSValue(range: addedRange)],
            suggestedActions: [copy]))
        #expect(menu.children.first === copy)
        let section = try #require(menu.children.last as? UIMenu)
        let action = try #require(section.children.first as? UIAction)
        #expect(action.title == "Add Comment")
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(quotes.count == 1)
        #expect(try #require(quotes.first).utf8.elementsEqual(added.utf8))
        #expect(editor.text.utf8.elementsEqual(source.utf8))
        #expect(editor.generation == 0)
        #expect(editor.textView.selectedRange == selection)
      }

      @Test func explicitRevealCanReturnToTheSameSelectedQuoteWithoutChangingSource() async throws {
        let text =
          "# Start\n\n" + String(repeating: "Room for another thought.\n\n", count: 60)
          + "A late native passage."
        let editor = Editor(fileID: "repeat-reveal", text: text)
        let window = host(editor)
        defer { window.isHidden = true }
        editor.textView.resignFirstResponder()
        var configuration = CommentHighlightConfiguration(
          quotes: [CommentQuote(commentID: 60, quote: "late native passage")], selectedCommentID: 60
        )
        editor.setCommentHighlights(configuration)
        try await settle(editor.textView) { editor.textView.contentOffset.y > 100 }
        #expect(editor.textView.contentOffset.y > 100)
        let top = CGPoint(x: 0, y: -editor.textView.adjustedContentInset.top)
        editor.textView.setContentOffset(top, animated: false)
        editor.setCommentHighlights(configuration)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(editor.textView.contentOffset.y - top.y) < 1)
        configuration.revealRevision += 1
        editor.setCommentHighlights(configuration)
        try await settle(editor.textView) { editor.textView.contentOffset.y > 100 }
        #expect(editor.textView.contentOffset.y > 100)
        #expect(editor.text == text)
        #expect(editor.generation == 0)
      }

      @Test func addCommentRequiresOneEligibleSelectionAndAnExplicitCallback() {
        let editor = Editor(fileID: "eligibility", text: "abc abcd 🫧🫧")
        let range = NSValue(range: NSRange(location: 4, length: 4))
        #expect(
          editor.textView(
            editor.textView, editMenuForTextInRanges: [range], suggestedActions: []) == nil)
        editor.setCommentHighlights(.init(), onAddComment: { _ in })
        #expect(
          editor.textView(
            editor.textView,
            editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
            suggestedActions: []) == nil)
        #expect(
          editor.textView(
            editor.textView, editMenuForTextInRanges: [range, range], suggestedActions: []) == nil)
        #expect(
          editor.textView(
            editor.textView, editMenuForTextInRanges: [range], suggestedActions: []) != nil)
        #expect(
          editor.textView(
            editor.textView,
            editMenuForTextInRanges: [NSValue(range: NSRange(location: 9, length: 4))],
            suggestedActions: []) != nil)
      }

      @Test func hidingIdleAnnotationsKeepsSelectionAndContextualDiscovery() throws {
        let editor = Editor(fileID: "visibility", text: "one two three")
        editor.setCommentHighlights(
          .init(
            quotes: [
              CommentQuote(commentID: 10, quote: "one two"),
              CommentQuote(commentID: 20, quote: "two three"),
            ], selectedCommentID: 20, showsInlineComments: false),
          onOpenCommentThreads: { _ in })
        #expect(
          editor.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 1, effectiveRange: nil) == nil)
        #expect(
          editor.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) != nil)
        let menu = editor.textView(
          editor.textView,
          editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
          suggestedActions: [])
        #expect(menu != nil)
      }

      @Test func missingAmbiguousAndHiddenFrontMatterQuotesDoNotInventLinks() async {
        let editor = Editor(
          fileID: "frontmatter", text: "---\ntitle: native\n---\n\nA native note")
        var linked: Set<Int64> = []
        editor.setCommentHighlights(
          .init(quotes: [
            CommentQuote(commentID: 10, quote: "native"),
            CommentQuote(commentID: 20, quote: "title: native"),
            CommentQuote(commentID: 30, quote: "missing"),
            CommentQuote(commentID: 40, quote: "native note"),
          ]), onLinkedCommentIDsChange: { linked = $0 })
        await Task.yield()
        #expect(linked == [40])
        #expect(
          editor.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) == nil)
        editor.setShowsFrontMatter(true)
        await Task.yield()
        #expect(linked == [20, 40])
        #expect(
          editor.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) != nil)
      }

      @Test func highlightsStepAsideForWritingToolsAndFindWithoutChangingSource() async throws {
        let editor = Editor(fileID: "transient-ui", text: "A native note")
        let window = host(editor)
        defer { window.isHidden = true }
        let view = editor.textView
        let annotated = {
          view.textStorage.attribute(CommentHighlights.annotationKey, at: 3, effectiveRange: nil)
            != nil
        }
        editor.setCommentHighlights(
          .init(quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        #expect(annotated())
        editor.textViewWritingToolsWillBegin(view)
        #expect(editor.isWritingToolsActive)
        #expect(!annotated())
        editor.textViewWritingToolsDidEnd(view)
        editor.highlight()
        #expect(annotated())

        let interaction = try #require(view.findInteraction)
        interaction.presentFindNavigator(showingReplace: false)
        try await settle(view) { interaction.isFindNavigatorVisible && !annotated() }
        #expect(interaction.isFindNavigatorVisible)
        #expect(!annotated())
        interaction.dismissFindNavigator()
        try await settle(view) { !interaction.isFindNavigatorVisible && annotated() }
        #expect(!interaction.isFindNavigatorVisible)
        #expect(annotated())
        #expect(editor.text == "A native note")
        #expect(editor.generation == 0)
      }

      @Test func selectedCommentHasNativeAccessibilityStateWithoutChangingTheEditorRole() throws {
        let editor = Editor(fileID: "accessibility", text: "A native note")
        let provider = try #require(editor.textView as? any AXCustomContentProvider)
        editor.setCommentHighlights(
          .init(
            quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        let content = try #require(provider.accessibilityCustomContent.first)
        #expect(content.label == "Selected Comment")
        #expect(content.value == "native")
        #expect(content.importance == .high)
        editor.setCommentHighlights(.init())
        #expect(provider.accessibilityCustomContent.isEmpty)
      }

      private func settle(_ view: UITextView, until condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
          view.setNeedsLayout()
          view.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(25))
        }
      }
    }
  }
#endif
