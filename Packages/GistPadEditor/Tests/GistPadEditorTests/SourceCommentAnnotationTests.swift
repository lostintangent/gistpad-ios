#if canImport(UIKit)
  import Accessibility
  import GistPadAppearance
  import GistPadComments
  import Testing
  import UIKit
  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct SourceCommentAnnotationTests {
    @Test func selectedLineBackgroundsMergeOverlapPartitionsWithoutBridgingLinesOrGaps() {
      let frames = [
        CGRect(x: 30, y: 10, width: 30, height: 20),
        CGRect(x: 10, y: 35, width: 25, height: 20),
        CGRect(x: 80, y: 10, width: 10, height: 20),
        CGRect(x: 10, y: 10, width: 20, height: 20),
      ]
      #expect(SourceCommentAnnotations.continuousLineRects(frames) == [
        CGRect(x: 10, y: 10, width: 50, height: 20),
        CGRect(x: 80, y: 10, width: 10, height: 20),
        CGRect(x: 10, y: 35, width: 25, height: 20),
      ])
    }

    @Test func annotationsPreserveExactSourceGenerationSelectionAndNativeUndo() throws {
      let session = DocumentSession(documentID: "comments", text: "A native note", generation: 7)
      let window = host(session)
      defer { window.isHidden = true }
      let undo = try #require(session.textView.undoManager)
      undo.removeAllActions()
      let mutation = SourceMutation(
        range: NSRange(location: 0, length: 1), expected: "A", replacement: "The")
      try session.apply(mutation, documentID: session.documentID, generation: 7)
      session.textView.selectedRange = NSRange(location: 4, length: 6)
      let selection = session.textView.selectedRange
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
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
      let session = DocumentSession(documentID: "overlap", text: "one two three")
      var opened: [[Int64]] = []
      session.setCommentHighlights(
        .init(quotes: [
          CommentQuote(commentID: 10, quote: "one two"),
          CommentQuote(commentID: 20, quote: "two three"),
        ]), onOpenCommentThreads: { opened.append($0) })
      #expect(
        session.textView.textStorage.attribute(
          SourceCommentAnnotations.annotationKey, at: 5, effectiveRange: nil) != nil)
      #expect(
        session.textView.textStorage.attribute(.textHighlightStyle, at: 5, effectiveRange: nil) == nil)
      #expect(
        session.textView.textStorage.attribute(
          .textItemTag, at: 5, effectiveRange: nil) == nil)
      let copy = UIAction(title: "System Copy") { _ in }
      let delegate: any UITextViewDelegate = session
      let menu = try #require(
        delegate.textView?(
          session.textView, editMenuForTextInRanges: [NSValue(range: NSRange(location: 4, length: 3))],
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

    @Test func sourceHitTestingMatchesNativeTextInputGeometry() throws {
      let source = "# Comment notebook\n\n🫧 A quiet native note, with **careful** words.\n"
      let session = DocumentSession(documentID: "hit-testing", text: source)
      let window = host(session)
      defer { window.isHidden = true }
      session.textView.resignFirstResponder()
      session.setCommentHighlights(
        .init(quotes: [
          CommentQuote(commentID: 10, quote: "quiet native"),
          CommentQuote(commentID: 20, quote: "native note"),
        ]), onOpenCommentThreads: { _ in })
      session.textView.layoutIfNeeded()
      let range = (source as NSString).range(of: "native")
      let start = try #require(
        session.textView.position(from: session.textView.beginningOfDocument, offset: range.location))
      let end = try #require(session.textView.position(from: start, offset: range.length))
      let selection = try #require(session.textView.textRange(from: start, to: end))
      let frame = session.textView.firstRect(for: selection)
      #expect(!frame.isEmpty)
      #expect(
        session.commentAnnotations.threadIDs(at: CGPoint(x: frame.midX, y: frame.midY)) == [10, 20],
        "Native frame \(frame), container inset \(session.textView.textContainerInset)")
    }

    @Test func explicitRevealCanReturnToTheSameSelectedQuoteWithoutChangingSource() async throws {
      let text = "# Start\n\n" + String(repeating: "Room for another thought.\n\n", count: 60)
        + "A late native passage."
      let session = DocumentSession(documentID: "repeat-reveal", text: text)
      let window = host(session)
      defer { window.isHidden = true }
      session.textView.resignFirstResponder()
      var configuration = CommentHighlightConfiguration(
        quotes: [CommentQuote(commentID: 60, quote: "late native passage")], selectedCommentID: 60)
      session.setCommentHighlights(configuration)
      for _ in 0..<40 {
        if session.textView.contentOffset.y > 100 { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(session.textView.contentOffset.y > 100)
      let top = CGPoint(x: 0, y: -session.textView.adjustedContentInset.top)
      session.textView.setContentOffset(top, animated: false)
      session.setCommentHighlights(configuration)
      try await Task.sleep(for: .milliseconds(50))
      #expect(abs(session.textView.contentOffset.y - top.y) < 1)
      configuration.revealRevision += 1
      session.setCommentHighlights(configuration)
      for _ in 0..<40 {
        if session.textView.contentOffset.y > 100 { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(session.textView.contentOffset.y > 100)
      #expect(session.text == text)
      #expect(session.generation == 0)
    }

    @Test func addCommentPreservesTheExactSelectionAndSystemMenu() throws {
      let source = "  cafe\u{0301} 🫧\r\n"
      let session = DocumentSession(documentID: "add-comment", text: source)
      var quotes: [String] = []
      session.setCommentHighlights(.init(), onAddComment: { quotes.append($0) })
      let copy = UIAction(title: "System Copy") { _ in }
      let selection = session.textView.selectedRange
      let menu = try #require(
        session.textView(
          session.textView,
          editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: source.utf16.count))],
          suggestedActions: [copy]))
      #expect(menu.children.first === copy)
      let section = try #require(menu.children.last as? UIMenu)
      let action = try #require(section.children.first as? UIAction)
      #expect(action.title == "Add Comment")
      let button = UIButton()
      button.addAction(action, for: .touchUpInside)
      button.sendActions(for: .touchUpInside)
      #expect(quotes.count == 1)
      #expect(try #require(quotes.first).utf8.elementsEqual(source.utf8))
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(session.textView.selectedRange == selection)
    }

    @Test func addCommentRequiresOneEligibleSelectionAndAnExplicitCallback() {
      let session = DocumentSession(documentID: "eligibility", text: "abc abcd 🫧🫧")
      let range = NSValue(range: NSRange(location: 4, length: 4))
      #expect(
        session.textView(
          session.textView, editMenuForTextInRanges: [range], suggestedActions: []) == nil)
      session.setCommentHighlights(.init(), onAddComment: { _ in })
      #expect(
        session.textView(
          session.textView, editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
          suggestedActions: []) == nil)
      #expect(
        session.textView(
          session.textView, editMenuForTextInRanges: [range, range], suggestedActions: []) == nil)
      #expect(
        session.textView(
          session.textView, editMenuForTextInRanges: [range], suggestedActions: []) != nil)
      #expect(
        session.textView(
          session.textView, editMenuForTextInRanges: [NSValue(range: NSRange(location: 9, length: 4))],
          suggestedActions: []) != nil)
    }

    @Test func changingOnlyQuoteNormalizationInvalidatesTheLiteralMatchCache() {
      let source = "A café note"
      let session = DocumentSession(documentID: "normalization", text: source)
      session.setCommentHighlights(
        .init(quotes: [
          CommentQuote(commentID: 10, quote: "café note")
        ]))
      #expect(
        session.textView.textStorage.attribute(SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil)
          != nil)
      session.setCommentHighlights(
        .init(quotes: [
          CommentQuote(commentID: 10, quote: "cafe\u{0301} note")
        ]))
      #expect(
        session.textView.textStorage.attribute(SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil)
          == nil)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
    }

    @Test func hidingIdleAnnotationsKeepsSelectionAndContextualDiscovery() throws {
      let session = DocumentSession(documentID: "visibility", text: "one two three")
      session.setCommentHighlights(
        .init(
          quotes: [
            CommentQuote(commentID: 10, quote: "one two"),
            CommentQuote(commentID: 20, quote: "two three"),
          ], selectedCommentID: 20, showsInlineComments: false),
        onOpenCommentThreads: { _ in })
      #expect(
        session.textView.textStorage.attribute(
          SourceCommentAnnotations.annotationKey, at: 1, effectiveRange: nil) == nil)
      #expect(
        session.textView.textStorage.attribute(
          SourceCommentAnnotations.annotationKey, at: 5, effectiveRange: nil) != nil)
      let menu = session.textView(
        session.textView, editMenuForTextInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
        suggestedActions: [])
      #expect(menu != nil)
    }

    @Test func missingAmbiguousAndHiddenFrontMatterQuotesDoNotInventLinks() async {
      let session = DocumentSession(
        documentID: "frontmatter", text: "---\ntitle: native\n---\n\nA native note")
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
          SourceCommentAnnotations.annotationKey, at: 5, effectiveRange: nil) == nil)
      session.setShowsFrontMatter(true)
      await Task.yield()
      #expect(linked == [20, 40])
      #expect(
        session.textView.textStorage.attribute(
          SourceCommentAnnotations.annotationKey, at: 5, effectiveRange: nil) != nil)
    }

    @Test func nativeSelectionRetainsOriginalInkInsteadOfSelectedCommentInk() throws {
      let session = DocumentSession(documentID: "selection", text: "A native note")
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
      let session = DocumentSession(documentID: "syntax-ink", text: source)
      let window = host(session)
      defer { window.isHidden = true }
      let original = NSAttributedString(attributedString: session.textView.textStorage)
      session.setCommentHighlights(
        .init(quotes: [CommentQuote(commentID: 10, quote: source)], selectedCommentID: 10))
      let selection = NSRange(location: 0, length: source.utf16.count)
      session.textView.selectedRange = selection
      session.textViewDidChangeSelection(session.textView)
      let restored = NSMutableAttributedString(attributedString: session.textView.textStorage)
      restored.removeAttribute(SourceCommentAnnotations.annotationKey, range: selection)
      #expect(restored.isEqual(to: original))
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(session.textView.selectedRange == selection)
    }

    @Test func writingToolsTemporarilyOwnsTextPresentationWithoutChangingSource() {
      let session = DocumentSession(documentID: "writing-tools", text: "A native note")
      session.setCommentHighlights(
        .init(
          quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
      session.textViewWritingToolsWillBegin(session.textView)
      #expect(
        session.textView.textStorage.attribute(
          SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil) == nil)
      #expect(session.writingToolsActive)
      session.textViewWritingToolsDidEnd(session.textView)
      session.highlight()
      #expect(
        session.textView.textStorage.attribute(
          SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil) != nil)
      #expect(session.text == "A native note")
      #expect(session.generation == 0)
    }

    @Test func nativeFindTemporarilyOwnsPresentationAndRestoresAnnotations() async throws {
      let session = DocumentSession(documentID: "find-comments", text: "A native note")
      let window = host(session)
      defer { window.isHidden = true }
      session.setCommentHighlights(
        .init(quotes: [CommentQuote(commentID: 10, quote: "native")], selectedCommentID: 10))
      let interaction = try #require(session.textView.findInteraction)
      interaction.presentFindNavigator(showingReplace: false)
      for _ in 0..<40 {
        session.textView.setNeedsLayout()
        session.textView.layoutIfNeeded()
        if interaction.isFindNavigatorVisible,
          session.textView.textStorage.attribute(SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil)
            == nil
        {
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(interaction.isFindNavigatorVisible)
      #expect(
        session.textView.textStorage.attribute(SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil)
          == nil)
      interaction.dismissFindNavigator()
      for _ in 0..<40 {
        session.textView.setNeedsLayout()
        session.textView.layoutIfNeeded()
        if !interaction.isFindNavigatorVisible,
          session.textView.textStorage.attribute(SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil)
            != nil
        {
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(!interaction.isFindNavigatorVisible)
      #expect(
        session.textView.textStorage.attribute(SourceCommentAnnotations.annotationKey, at: 3, effectiveRange: nil)
          != nil)
      #expect(session.text == "A native note")
      #expect(session.generation == 0)
    }

    @Test func idleFillStartsAtHalfAccentAndPreservesOpaqueAndAlphaInkContrast() {
      let accent = PersonalAccent(savedHex: "#FACC15")
      let fill = SourceCommentAnnotations.idleFill(
        accent: accent.color, page: .white, inks: [(.black, 1)], target: 4.5)
      #expect(fill.hex == "#FDE68A")
      for page in [RGBColor.white, .black] {
        let inks: [(RGBColor, Double)] = [
          (page == .white ? .black : .white, 1),
          (RGBColor(red: 0, green: 122, blue: 255), 1),
          (RGBColor(red: 60, green: 60, blue: 67), 0.6),
        ]
        for target in [4.5, 7.0] {
          let background = SourceCommentAnnotations.idleFill(
            accent: accent.color, page: page, inks: inks, target: target)
          for (ink, opacity) in inks {
            let minimum = min(target, page.mixed(toward: ink, amount: opacity).contrast(with: page))
            #expect(
              background.mixed(toward: ink, amount: opacity).contrast(with: background)
                + 0.000_001 >= minimum)
          }
        }
      }
      #expect(accent.savedHex == "#FACC15")
      #expect(accent.color.hex == "#FACC15")
    }

    @Test func selectedCommentHasNativeAccessibilityStateWithoutChangingTheEditorRole() throws {
      let session = DocumentSession(documentID: "accessibility", text: "A native note")
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

    private func host(_ session: DocumentSession) -> UIWindow {
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      let controller = UIViewController()
      window.rootViewController = controller
      session.textView.frame = controller.view.bounds
      session.textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      controller.view.addSubview(session.textView)
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
      session.textView.becomeFirstResponder()
      return window
    }
  }
#endif
