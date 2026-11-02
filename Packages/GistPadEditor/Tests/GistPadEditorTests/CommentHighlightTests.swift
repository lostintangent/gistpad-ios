#if canImport(UIKit)
  import Accessibility
  import GistPadComments
  import Testing
  import UIKit
  @testable import GistPadEditor

  extension HostedEditorTests {
    @MainActor
    struct CommentHighlightTests {
      @Test func annotationsPreserveExactSourceGenerationSelectionAndNativeUndo() throws {
        let session = Editor(fileID: "comments", text: "A native note", generation: 7)
        let window = host(session)
        defer { window.isHidden = true }
        let undo = try #require(session.textView.undoManager)
        undo.removeAllActions()
        try session.apply(
          Edit(range: NSRange(location: 0, length: 1), expected: "A", replacement: "The"),
          generation: 7)
        session.textView.selectedRange = NSRange(location: 4, length: 6)
        let selection = session.textView.selectedRange
        var changes = 0
        session.onEdit = { _, _ in changes += 1 }
        session.setCommentHighlights(
          .init(
            quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        session.highlight()
        #expect(session.text == "The native note")
        #expect(session.generation == 8)
        #expect(session.textView.selectedRange == selection)
        #expect(changes == 0)
        #expect(session.textView.textLayoutManager != nil)
        #expect(session.textView.typingAttributes[.textHighlightStyle] == nil)
        #expect(session.textView.typingAttributes[.textItemTag] == nil)
        undo.undo()
        session.textViewDidChange(session.textView)
        #expect(session.text == "A native note")
        #expect(!undo.canUndo)
        undo.redo()
        session.textViewDidChange(session.textView)
        #expect(session.text == "The native note")
      }

      @Test func overlapMenuKeepsSystemActionsAndOpensEveryThread() throws {
        let session = Editor(fileID: "overlap", text: "one two three")
        var opened: [[Int64]] = []
        session.setCommentHighlights(
          .init(quotes: [
            CommentQuote(commentID: 10, quote: "one two"),
            CommentQuote(commentID: 20, quote: "two three"),
          ]), onOpenCommentThreads: { opened.append($0) })
        #expect(
          session.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) != nil)
        #expect(
          session.textView.textStorage.attribute(.textHighlightStyle, at: 5, effectiveRange: nil)
            == nil)
        #expect(
          session.textView.textStorage.attribute(
            .textItemTag, at: 5, effectiveRange: nil) == nil)
        let copy = UIAction(title: "System Copy") { _ in }
        let delegate: any UITextViewDelegate = session
        let menu = try #require(
          delegate.textView?(
            session.textView,
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
        #expect(session.text == "one two three")
        #expect(session.generation == 0)
      }

      @Test func passagesHitTestNativeGeometryAndAddCommentKeepsTheExactSelection() throws {
        let added = "  cafe\u{0301} 🫧\r\n"
        let source =
          "# Comment notebook\n\n🫧 A quiet native note, with **careful** words.\n" + added
        let session = Editor(fileID: "hit-testing", text: source)
        let window = host(session, focused: false)
        defer { window.isHidden = true }
        var quotes: [String] = []
        session.setCommentHighlights(
          .init(quotes: [
            CommentQuote(commentID: 10, quote: "quiet native"),
            CommentQuote(commentID: 20, quote: "native note"),
          ]), onOpenCommentThreads: { _ in }, onAddComment: { quotes.append($0) })
        session.textView.layoutIfNeeded()
        let range = (source as NSString).range(of: "native")
        let start = try #require(
          session.textView.position(
            from: session.textView.beginningOfDocument, offset: range.location))
        let end = try #require(session.textView.position(from: start, offset: range.length))
        let frame = session.textView.firstRect(
          for: try #require(session.textView.textRange(from: start, to: end)))
        #expect(!frame.isEmpty)
        #expect(
          session.commentHighlights.threadIDs(
            at: CGPoint(x: frame.midX, y: frame.midY)) == [10, 20],
          "Native frame \(frame), container inset \(session.textView.textContainerInset)")

        let copy = UIAction(title: "System Copy") { _ in }
        let selection = session.textView.selectedRange
        let addedRange = NSRange(
          location: source.utf16.count - added.utf16.count, length: added.utf16.count)
        let menu = try #require(
          session.textView(
            session.textView, editMenuForTextInRanges: [NSValue(range: addedRange)],
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
        #expect(session.text.utf8.elementsEqual(source.utf8))
        #expect(session.generation == 0)
        #expect(session.textView.selectedRange == selection)
      }

      @Test func explicitRevealCanReturnToTheSameSelectedQuoteWithoutChangingSource() async throws {
        let text =
          "# Start\n\n" + String(repeating: "Room for another thought.\n\n", count: 60)
          + "A late native passage."
        let session = Editor(fileID: "repeat-reveal", text: text)
        let window = host(session)
        defer { window.isHidden = true }
        session.textView.resignFirstResponder()
        var configuration = CommentHighlightConfiguration(
          quotes: [CommentQuote(commentID: 60, quote: "late native passage")], selectedCommentID: 60
        )
        session.setCommentHighlights(configuration)
        try await settle(session.textView) { session.textView.contentOffset.y > 100 }
        #expect(session.textView.contentOffset.y > 100)
        let top = CGPoint(x: 0, y: -session.textView.adjustedContentInset.top)
        session.textView.setContentOffset(top, animated: false)
        session.setCommentHighlights(configuration)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(session.textView.contentOffset.y - top.y) < 1)
        configuration.revealRevision += 1
        session.setCommentHighlights(configuration)
        try await settle(session.textView) { session.textView.contentOffset.y > 100 }
        #expect(session.textView.contentOffset.y > 100)
        #expect(session.text == text)
        #expect(session.generation == 0)
      }

      @Test func addCommentRequiresOneEligibleSelectionAndAnExplicitCallback() {
        let session = Editor(fileID: "eligibility", text: "abc abcd 🫧🫧")
        let range = NSValue(range: NSRange(location: 4, length: 4))
        #expect(
          session.textView(
            session.textView, editMenuForTextInRanges: [range], suggestedActions: []) == nil)
        session.setCommentHighlights(.init(), onAddComment: { _ in })
        #expect(
          session.textView(
            session.textView,
            editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
            suggestedActions: []) == nil)
        #expect(
          session.textView(
            session.textView, editMenuForTextInRanges: [range, range], suggestedActions: []) == nil)
        #expect(
          session.textView(
            session.textView, editMenuForTextInRanges: [range], suggestedActions: []) != nil)
        #expect(
          session.textView(
            session.textView,
            editMenuForTextInRanges: [NSValue(range: NSRange(location: 9, length: 4))],
            suggestedActions: []) != nil)
      }

      @Test func hidingIdleAnnotationsKeepsSelectionAndContextualDiscovery() throws {
        let session = Editor(fileID: "visibility", text: "one two three")
        session.setCommentHighlights(
          .init(
            quotes: [
              CommentQuote(commentID: 10, quote: "one two"),
              CommentQuote(commentID: 20, quote: "two three"),
            ], selectedCommentID: 20, showsInlineComments: false),
          onOpenCommentThreads: { _ in })
        #expect(
          session.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 1, effectiveRange: nil) == nil)
        #expect(
          session.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) != nil)
        let menu = session.textView(
          session.textView,
          editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
          suggestedActions: [])
        #expect(menu != nil)
      }

      @Test func missingAmbiguousAndHiddenFrontMatterQuotesDoNotInventLinks() async {
        let session = Editor(
          fileID: "frontmatter", text: "---\ntitle: native\n---\n\nA native note")
        var linked: Set<Int64> = []
        session.setCommentHighlights(
          .init(quotes: [
            CommentQuote(commentID: 10, quote: "native"),
            CommentQuote(commentID: 20, quote: "title: native"),
            CommentQuote(commentID: 30, quote: "missing"),
            CommentQuote(commentID: 40, quote: "native note"),
          ]), onLinkedCommentIDsChange: { linked = $0 })
        await Task.yield()
        #expect(linked == [40])
        #expect(
          session.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) == nil)
        session.setShowsFrontMatter(true)
        await Task.yield()
        #expect(linked == [20, 40])
        #expect(
          session.textView.textStorage.attribute(
            CommentHighlights.annotationKey, at: 5, effectiveRange: nil) != nil)
      }

      @Test func nativeSelectionRetainsOriginalInkInsteadOfSelectedCommentInk() throws {
        let session = Editor(fileID: "selection", text: "A native note")
        let window = host(session)
        defer { window.isHidden = true }
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        let original = try #require(
          session.textView.textStorage.attribute(
            .foregroundColor, at: 3, effectiveRange: nil) as? UIColor)
        session.setCommentHighlights(
          .init(
            quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        session.textView.selectedRange = NSRange(location: 2, length: 6)
        session.textViewDidChangeSelection(session.textView)
        let selected = try #require(
          session.textView.textStorage.attribute(
            .foregroundColor, at: 3, effectiveRange: nil) as? UIColor)
        #expect(
          selected.resolvedColor(with: session.textView.traitCollection)
            == original.resolvedColor(with: session.textView.traitCollection))
        #expect(session.textView.tintColor == .systemBlue)
        #expect(session.textView.selectedRange == NSRange(location: 2, length: 6))
      }

      @Test func selectingACommentRestoresEachSyntaxInkWithoutChangingOtherAttributes() throws {
        let source = "A **native** `code` [note](https://example.test)"
        let session = Editor(fileID: "syntax-ink", text: source)
        let window = host(session)
        defer { window.isHidden = true }
        let original = NSAttributedString(attributedString: session.textView.textStorage)
        session.setCommentHighlights(
          .init(quotes: [CommentQuote(commentID: 10, quote: source)], selectedCommentID: 10))
        let selection = NSRange(location: 0, length: source.utf16.count)
        session.textView.selectedRange = selection
        session.textViewDidChangeSelection(session.textView)
        let restored = NSMutableAttributedString(attributedString: session.textView.textStorage)
        restored.removeAttribute(CommentHighlights.annotationKey, range: selection)
        #expect(restored.isEqual(to: original))
        #expect(session.text.utf8.elementsEqual(source.utf8))
        #expect(session.generation == 0)
        #expect(session.textView.selectedRange == selection)
      }

      @Test func highlightsStepAsideForWritingToolsAndFindWithoutChangingSource() async throws {
        let session = Editor(fileID: "transient-ui", text: "A native note")
        let window = host(session)
        defer { window.isHidden = true }
        let view = session.textView
        let annotated = {
          view.textStorage.attribute(CommentHighlights.annotationKey, at: 3, effectiveRange: nil)
            != nil
        }
        session.setCommentHighlights(
          .init(quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        #expect(annotated())
        session.textViewWritingToolsWillBegin(view)
        #expect(session.isWritingToolsActive)
        #expect(!annotated())
        session.textViewWritingToolsDidEnd(view)
        session.highlight()
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
        #expect(session.text == "A native note")
        #expect(session.generation == 0)
      }

      @Test func selectedCommentHasNativeAccessibilityStateWithoutChangingTheEditorRole() throws {
        let session = Editor(fileID: "accessibility", text: "A native note")
        let provider = try #require(session.textView as? any AXCustomContentProvider)
        session.setCommentHighlights(
          .init(
            quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
        let content = try #require(provider.accessibilityCustomContent.first)
        #expect(content.label == "Selected Comment")
        #expect(content.value == "native")
        #expect(content.importance == .high)
        #expect(session.textView.accessibilityLabel == "Markdown source")
        session.setCommentHighlights(.init())
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
