#if canImport(UIKit)
  import Accessibility
  import Appearance
  import AppIntents
  import Comments
  import Observation
  import SwiftUI
  import UIKit

  @MainActor
  @Observable
  public final class Editor: NSObject, Identifiable, UITextViewDelegate,
    @MainActor NSTextContentStorageDelegate
  {
    public let id = UUID()
    public private(set) var text: String
    public private(set) var generation: UInt64
    private(set) var isComposing = false
    public private(set) var isEditing = false
    public private(set) var isWritingToolsActive = false
    private(set) var showsFrontMatter = false
    public private(set) var contentStart = 0
    public var inputError: String?
    let textView = TextView(usingTextLayoutManager: true)
    @ObservationIgnored weak var host: TextViewHost?
    @ObservationIgnored var hosts: [TextViewHost.Reference] = []
    @ObservationIgnored public var onEdit: ((String, UInt64) -> Void)?
    @ObservationIgnored private var isHighlighting = false
    /// A caret placed by a focus request, waiting for the text view to reach a window.
    @ObservationIgnored public private(set) var isFocusPending = false
    @ObservationIgnored lazy var commentHighlights = CommentHighlights(editor: self)

    public init(
      text: String, generation: UInt64 = 0, showsFrontMatter: Bool = false
    ) {
      self.text = text
      self.generation = generation
      self.showsFrontMatter = showsFrontMatter
      super.init()
      textView.editor = self
      textView.installIndentSwipes()
      textView.delegate = self
      textView.text = text
      textView.font = .preferredFont(forTextStyle: .body)
      textView.adjustsFontForContentSizeCategory = true
      textView.backgroundColor = .systemBackground
      textView.tintColor = .systemBlue
      textView.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 40, right: 20)
      textView.alwaysBounceVertical = true
      textView.topEdgeEffect.style = .soft
      textView.bottomEdgeEffect.style = .soft
      textView.isFindInteractionEnabled = true
      textView.accessibilityIdentifier = "source-editor"
      textView.smartQuotesType = .no
      textView.smartDashesType = .no
      textView.writingToolsBehavior = .complete
      textView.allowedWritingToolsResultOptions = .plainText
      textView.textLayoutManager?.textContentManager?.delegate = self
      textView.registerForTraitChanges([
        UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self,
        UITraitAccessibilityContrast.self, UITraitLegibilityWeight.self,
      ]) { (view: TextView, _: UITraitCollection) in
        view.editor?.highlight()
      }
      textView.registerForTraitChanges([AccentTrait.self]) {
        (view: TextView, _: UITraitCollection) in
        view.editor?.commentHighlights.accentDidChange()
      }
      updateHiddenFrontMatter()
      textView.selectedRange = NSRange(location: contentStart, length: 0)
      highlight()
    }

    /// Applies one change as an undoable step. A nil selection keeps the caret where it was.
    public func apply(_ edit: Edit, generation: UInt64) throws {
      guard isSettled else { throw Edit.Failure.compositionActive }
      guard self.generation == generation else { throw Edit.Failure.staleGeneration }
      _ = try edit.applying(to: text)
      // An edit that changes nothing, like stepping over a closer, only moves the caret.
      if edit.range.length == 0, edit.replacement.isEmpty {
        if let selection = edit.selection { textView.selectedRange = selection }
        return
      }
      let previousSelection = textView.selectedRange
      let inverse = Edit(
        range: NSRange(location: edit.range.location, length: edit.replacement.utf16.count),
        expected: edit.replacement,
        replacement: (text as NSString).substring(with: edit.range),
        selection: previousSelection)
      let undo = textView.undoManager
      undo?.beginUndoGrouping()
      // Source transactions bypass input substitutions and restore the exact source and selection.
      undo?.disableUndoRegistration()
      textView.textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
      updateHiddenFrontMatter()
      let delta = edit.replacement.utf16.count - edit.range.length
      if let selection = edit.selection {
        textView.selectedRange = selection
      } else if NSMaxRange(previousSelection) <= edit.range.location {
        textView.selectedRange = previousSelection
      } else if previousSelection.location >= NSMaxRange(edit.range) {
        textView.selectedRange = NSRange(
          location: previousSelection.location + delta, length: previousSelection.length)
      }
      undo?.enableUndoRegistration()
      undo?.registerUndo(withTarget: self) { editor in
        do {
          try editor.apply(inverse, generation: editor.generation)
        } catch {
          editor.inputError = error.localizedDescription
        }
      }
      undo?.endUndoGrouping()
      synchronizeText()
      if let selection = edit.selection { textView.scrollRangeToVisible(selection) }
    }

    /// Nothing is mid-input: no marked text, dictation or Writing Tools session.
    public var isSettled: Bool {
      !isComposing && !isWritingToolsActive && textView.markedTextRange == nil
    }

    public var canFormat: Bool { textView.isEditable && isSettled }

    /// Locking the editor puts the keyboard away, so a change landing in the note can't race typing.
    public var isEditable: Bool {
      get { textView.isEditable }
      set { textView.isEditable = newValue }
    }

    public var isSpellCheckingEnabled: Bool {
      get { textView.spellCheckingType != .no }
      set { textView.spellCheckingType = newValue ? .yes : .no }
    }

    /// Brings the keyboard back where the caret is, as after a sheet closes or a lock lifts.
    public func focus() {
      guard canFormat, !textView.isHidden, textView.window != nil else { return }
      becomeFirstResponder()
    }

    /// Puts the keyboard away.
    public func endEditing() {
      textView.resignFirstResponder()
    }

    public var selection: NSRange { textView.selectedRange }

    /// Selects `range` and brings it on screen, as when a citation or reference opens the note.
    public func select(_ range: NSRange) {
      textView.selectedRange = range
      textView.layoutIfNeeded()
      textView.scrollRangeToVisible(range)
      becomeFirstResponder()
    }

    /// The note Siri and Apple Intelligence see while you're in the editor.
    public var entityIdentifier: EntityIdentifier? {
      get { textView.appEntityIdentifier }
      set { textView.appEntityIdentifier = newValue }
    }

    private func becomeFirstResponder() {
      if !textView.becomeFirstResponder() {
        inputError = String(localized: "Tap the file to resume writing.", bundle: .module)
      }
    }

    /// Keeps what the keyboard is composing as typed text, as leaving a note does in Notes.
    public func commitComposition() {
      guard textView.markedTextRange != nil else { return }
      textView.unmarkText()
      synchronizeText()
    }

    /// Puts the caret at the end, ready to write, as a new gist or today's note opens.
    public func requestFocusAtEnd() {
      guard canFormat else {
        inputError = String(
          localized: "Finish the current text edit before moving the caret.", bundle: .module)
        return
      }
      textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
      isFocusPending = true
      completeFocusRequestIfAttached()
    }

    /// Shows or hides the note's front matter, keeping what the keyboard is composing.
    public func setShowsFrontMatter(_ value: Bool) {
      guard value != showsFrontMatter else { return }
      commitComposition()
      showsFrontMatter = value
      updateHiddenFrontMatter()
      commentHighlights.frontMatterVisibilityDidChange()
    }

    public func textContentManager(
      _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
      options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
      guard contentStart > 0, let range = textElement.elementRange else { return true }
      return textContentManager.offset(
        from: textContentManager.documentRange.location, to: range.location) >= contentStart
    }

    private func updateHiddenFrontMatter() {
      let source: String = textView.text
      let start = showsFrontMatter ? 0 : Syntax.contentStart(in: source)
      textView.accessibilityValue = start > 0 ? (source as NSString).substring(from: start) : nil
      guard start != contentStart else { return }
      contentStart = start
      if let manager = textView.textLayoutManager,
        let range = manager.textContentManager?.documentRange
      {
        manager.invalidateLayout(for: range)
      }
      // The text view's selection setter keeps the caret out of hidden front matter.
      if textView.selectedRange.location < start { textView.selectedRange = textView.selectedRange }
      textView.resetReadingAnchor(to: start)
      textView.setNeedsLayout()
    }

    fileprivate func completeFocusRequestIfAttached() {
      guard isFocusPending, textView.window != nil else { return }
      isFocusPending = false
      textView.becomeFirstResponder()
      textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// A tap places its caret after this returns, so revealing the old caret would scroll away.
    public func textViewDidBeginEditing(_ textView: UITextView) {
      isEditing = true
    }

    public func textViewDidEndEditing(_: UITextView) {
      isEditing = false
      textView.cancelEditingCaretReveal()
      synchronizeText()
    }

    public func textViewDidChange(_ textView: UITextView) {
      synchronizeText()
    }

    public func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String
    ) -> Bool {
      guard range.location >= contentStart else { return false }
      guard canFormat,
        textView.findInteraction?.isFindNavigatorVisible != true
      else { return true }
      synchronizeText()
      do {
        guard let edit = try Typing.edit(in: text, selection: range, replacement: replacement)
        else { return true }
        try apply(edit, generation: generation)
        return false
      } catch {
        inputError = String(localized: "The file changed. Select the text again.", bundle: .module)
        return false
      }
    }

    func indent(outdent: Bool) {
      do {
        guard canFormat else { throw Edit.Failure.compositionActive }
        if let edit = try Typing.indent(
          in: text, selection: textView.selectedRange, outdent: outdent)
        {
          try apply(edit, generation: generation)
        }
      } catch {
        inputError = String(
          localized: "Finish the current text edit, then select the lines again.", bundle: .module)
      }
    }

    func indentSwipedLine(at point: CGPoint, outdent: Bool) -> Bool {
      guard canFormat, textView.findInteraction?.isFindNavigatorVisible != true,
        let position = textView.closestPosition(to: point)
      else { return false }
      let offset = textView.offset(from: textView.beginningOfDocument, to: position)
      guard Typing.isListItem(in: text, at: offset) else { return false }
      do {
        guard
          let edit = try Typing.indent(
            in: text, selection: NSRange(location: offset, length: 0), outdent: outdent,
            keeping: textView.selectedRange)
        else { return false }
        try apply(edit, generation: generation)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
      } catch {
        inputError = String(
          localized: "Finish the current text edit, then try again.", bundle: .module)
        return false
      }
    }

    public func find(replacing: Bool = false) {
      guard isSettled else {
        inputError = String(
          localized: "Finish the current text edit before finding text.", bundle: .module)
        return
      }
      commentHighlights.suspendForFind()
      textView.findInteraction?.presentFindNavigator(showingReplace: replacing)
    }

    public func textViewDidChangeSelection(_: UITextView) {
      // Re-setting runs the selection setter's clamp on selections UIKit makes itself.
      if textView.selectedRange.location < min(contentStart, textView.text.utf16.count) {
        textView.selectedRange = textView.selectedRange
      }
      isComposing = textView.markedTextRange != nil
      if isComposing { textView.cancelEditingCaretReveal() }
      commentHighlights.selectionDidChange()
    }

    public func textViewWritingToolsWillBegin(_: UITextView) {
      synchronizeText()
      commentHighlights.suspendForWritingTools()
      isWritingToolsActive = true
      textView.cancelEditingCaretReveal()
    }

    public func textViewWritingToolsDidEnd(_: UITextView) {
      isWritingToolsActive = false
      commentHighlights.resumeAfterWritingTools()
      synchronizeText()
      textView.rememberReadingAnchor()
    }

    public func textView(
      _ textView: UITextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
    ) -> [NSValue] {
      var ranges = Syntax.ignoredWritingToolsRanges(
        in: textView.text, enclosing: enclosingRange)
      var hidden = NSIntersectionRange(NSRange(location: 0, length: contentStart), enclosingRange)
      if hidden.length > 0 {
        while let first = ranges.first, first.location <= NSMaxRange(hidden) {
          hidden = NSUnionRange(hidden, first)
          ranges.removeFirst()
        }
        ranges.insert(hidden, at: 0)
      }
      return ranges.map(NSValue.init(range:))
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
      textView.rememberReadingAnchor()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      textView.cancelEditingCaretReveal()
    }

    public func setCommentHighlights(
      _ configuration: CommentHighlightConfiguration, actions: CommentHighlightActions? = nil
    ) {
      commentHighlights.configure(configuration, actions: actions)
    }

    public func textView(
      _ textView: UITextView, editMenuForTextInRanges ranges: [NSValue],
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      commentHighlights.editMenu(ranges: ranges.map(\.rangeValue), suggestedActions: suggestedActions)
    }

    // gistpad.dev's GitHub palette in Light, Dark, and each with Increase Contrast. Where the
    // web uses its text ink, nil keeps `label`: Light headings, bold and italic, and Dark link labels.
    private static let headingInk = ink(nil, 0xD2A8FF, highContrast: nil, 0xE6CCFF)
    private static let quoteInk = ink(0x22863A, 0x7EE787, highContrast: 0x155D27, 0xB0F5B7)
    private static let htmlTagInk = ink(0x116329, 0x7EE787, highContrast: 0x0B4B1E, 0xB0F5B7)
    private static let urlInk = ink(0x032F62, 0xA5D6FF, highContrast: 0x02234A, 0xD1ECFF)
    private static let linkLabelInk = ink(0x032F62, nil, highContrast: 0x02234A, nil)

    private static func ink(
      _ light: UInt32?, _ dark: UInt32?, highContrast highLight: UInt32?, _ highDark: UInt32?
    ) -> UIColor {
      UIColor { traits in
        let high = traits.accessibilityContrast == .high
        let hex =
          traits.userInterfaceStyle == .dark ? (high ? highDark : dark) : (high ? highLight : light)
        guard let hex else { return .label.resolvedColor(with: traits) }
        return UIColor(
          red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      }
    }

    func highlight() {
      guard isSettled, !isHighlighting else { return }
      isHighlighting = true
      defer { isHighlighting = false }
      let anchor = textView.beginAttributeUpdate()
      defer { textView.endAttributeUpdate(anchor) }
      let storage: NSTextStorage
      if case .caret? = anchor {
        storage = NSTextStorage(string: textView.text)
      } else {
        storage = textView.textStorage
      }
      let bodyFont = UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: textView.traitCollection)
      let boldText = textView.traitCollection.legibilityWeight == .bold
      let headingFont = UIFont.systemFont(
        ofSize: bodyFont.pointSize, weight: .bold)
      let codeFont = UIFont.monospacedSystemFont(
        ofSize: bodyFont.pointSize, weight: boldText ? .semibold : .regular)
      let selectedRange = textView.selectedRange
      let manager = textView.undoManager
      manager?.disableUndoRegistration()
      storage.beginEditing()
      storage.setAttributes(
        [
          .font: bodyFont,
          .foregroundColor: UIColor.label,
        ], range: NSRange(location: 0, length: storage.length))
      for span in Syntax.spans(in: textView.text) {
        let attributes: [NSAttributedString.Key: Any]
        switch span.kind {
        case .heading:
          attributes = [.foregroundColor: Self.headingInk, .font: headingFont]
        case .strong, .emphasis:
          attributes = [.foregroundColor: Self.headingInk]
        case .blockquote:
          attributes = [.foregroundColor: Self.quoteInk]
        case .htmlTag:
          attributes = [.foregroundColor: Self.htmlTagInk]
        case .orderedMarker, .punctuation, .task, .checkedTask:
          attributes = [.foregroundColor: UIColor.secondaryLabel]
        case .strikethrough:
          attributes = [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code:
          attributes = [
            .foregroundColor: UIColor.label,
            .font: codeFont,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
          ]
        case .frontmatter:
          attributes = [.foregroundColor: UIColor.label, .font: codeFont]
        case .link, .linkDestination:
          attributes = [
            .foregroundColor: span.kind == .link ? Self.linkLabelInk : Self.urlInk,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ]
        }
        storage.addAttributes(attributes, range: span.range)
        if span.kind == .strong || span.kind == .emphasis {
          let addedTrait: UIFontDescriptor.SymbolicTraits =
            span.kind == .strong ? .traitBold : .traitItalic
          storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
            guard let font = value as? UIFont,
              let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(addedTrait))
            else { preconditionFailure("The system source font must support Markdown emphasis.") }
            storage.addAttribute(
              .font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
          }
        }
      }
      commentHighlights.paint(in: storage)
      storage.endEditing()
      if storage !== textView.textStorage {
        applyChangedHighlightAttributes(storage, to: textView.textStorage)
      }
      manager?.enableUndoRegistration()
      if textView.selectedRange != selectedRange {
        textView.selectedRange = selectedRange
      }
      textView.typingAttributes = [
        .font: bodyFont,
        .foregroundColor: UIColor.label,
      ]
    }

    private func applyChangedHighlightAttributes(
      _ styled: NSAttributedString, to storage: NSTextStorage
    ) {
      storage.beginEditing()
      styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) {
        attributes, range, _ in
        storage.enumerateAttributes(in: range) { current, run, _ in
          for key in current.keys where attributes[key] == nil {
            storage.removeAttribute(key, range: run)
          }
          for (key, value) in attributes {
            if let existing = current[key] as? NSObject, existing.isEqual(value) { continue }
            storage.addAttribute(key, value: value, range: run)
          }
        }
      }
      storage.endEditing()
    }

    private func synchronizeText() {
      // Inline previews are transient. UIKit owns their selection and native undo history.
      guard !isWritingToolsActive else { return }
      isComposing = textView.markedTextRange != nil
      if !text.utf8.elementsEqual(textView.text.utf8) {
        text = textView.text
        updateHiddenFrontMatter()
        generation += 1
        textView.requestEditingCaretReveal()
        onEdit?(text, generation)
      }
      highlight()
    }
  }

  final class TextView: UITextView, @MainActor AXCustomContentProvider, UIGestureRecognizerDelegate {
    var accessibilityCustomContent: [AXCustomContent]! = []
    enum AttributeUpdateAnchor {
      case reading(offset: Int, delta: CGFloat)
      case caret
    }

    weak var editor: Editor?
    /// Writing Tools owns inline animations and scrolling until its session finishes.
    private var writingToolsOwnsScrolling: Bool { editor?.isWritingToolsActive == true }
    private var contentStart: Int { editor?.contentStart ?? 0 }
    private var previousWidth: CGFloat = 0
    private var previousHeight: CGFloat = 0
    private var readingOffset = 0
    private var anchorDelta: CGFloat = 0
    private var restoringAnchor = false
    private weak var viewportView: UIView?
    private var needsEditingCaretReveal = false

    override var selectedRange: NSRange {
      get { super.selectedRange }
      set {
        let start = max(min(contentStart, textStorage.length), newValue.location)
        let end = max(start, NSMaxRange(newValue))
        super.selectedRange = NSRange(location: start, length: end - start)
      }
    }

    /// Behind hidden front matter, UIKit's backspace at the first visible character deletes it instead.
    override func deleteBackward() {
      guard contentStart == 0 || selectedRange.location > contentStart || selectedRange.length > 0
      else { return }
      super.deleteBackward()
    }

    func installIndentSwipes() {
      for direction in [UISwipeGestureRecognizer.Direction.right, .left] {
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleIndentSwipe))
        swipe.direction = direction
        swipe.delegate = self
        addGestureRecognizer(swipe)
      }
    }

    @objc private func handleIndentSwipe(_ swipe: UISwipeGestureRecognizer) {
      _ = editor?.indentSwipedLine(at: swipe.location(in: self), outdent: swipe.direction == .left)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
    }

    func resetReadingAnchor(to offset: Int) {
      readingOffset = offset
      anchorDelta = adjustedContentInset.top + textContainerInset.top
      setVerticalContentOffset(-adjustedContentInset.top)
    }

    func requestEditingCaretReveal() {
      guard isFirstResponder, !writingToolsOwnsScrolling, markedTextRange == nil else { return }
      needsEditingCaretReveal = true
    }

    func cancelEditingCaretReveal() {
      needsEditingCaretReveal = false
    }

    func beginAttributeUpdate() -> AttributeUpdateAnchor? {
      guard window != nil, !writingToolsOwnsScrolling, !restoringAnchor,
        bounds.width > 0, previousWidth > 0, abs(previousWidth - bounds.width) < 1
      else { return nil }
      if isFirstResponder, let end = selectedTextRange?.end {
        guard markedTextRange == nil, !isTracking, !isDragging, !isDecelerating else { return nil }
        let caret = caretRect(for: end)
        if needsEditingCaretReveal || bounds.inset(by: adjustedContentInset).contains(caret) {
          restoringAnchor = true
          return .caret
        }
      }
      restoringAnchor = true
      return .reading(offset: readingOffset, delta: anchorDelta)
    }

    func endAttributeUpdate(_ anchor: AttributeUpdateAnchor?) {
      guard let anchor else { return }
      defer { restoringAnchor = false }
      switch anchor {
      case .reading(let offset, let delta):
        // Attribute invalidation can replace exact offscreen geometry with TextKit estimates.
        layoutDocument()
        super.layoutSubviews()
        if let position = position(from: beginningOfDocument, offset: offset) {
          setVerticalContentOffset(caretRect(for: position).minY - delta)
        }
      case .caret:
        if let manager = textLayoutManager, let content = manager.textContentManager,
          let location = content.location(
            content.documentRange.location, offsetBy: NSMaxRange(selectedRange))
        {
          manager.ensureLayout(for: NSTextRange(location: location))
        }
        super.layoutSubviews()
        reveal(NSMaxRange(selectedRange))
        needsEditingCaretReveal = false
      }
    }

    func updateViewportView(_ view: UIView) {
      viewportView = view
      setNeedsLayout()
    }

    /// UIKit insets the source below the bars. The keyboard and its bar aren't part of the safe
    /// area, so the viewport overlay measures them.
    private func applyViewportInsets() {
      guard let viewportView, window != nil, viewportView.window === window else { return }
      let viewport = convert(viewportView.bounds, from: viewportView)
      let automatic = adjustedContentInset.bottom - contentInset.bottom
      let bottom = max(0, bounds.maxY - viewport.maxY - automatic)
      guard abs(bottom - contentInset.bottom) > 0.001 else { return }
      let wasRestoring = restoringAnchor
      restoringAnchor = true
      defer { restoringAnchor = wasRestoring }
      let offset = contentOffset
      contentInset.bottom = bottom
      verticalScrollIndicatorInsets.bottom = bottom
      if !writingToolsOwnsScrolling, markedTextRange == nil, !isTracking, !isDecelerating {
        setVerticalContentOffset(offset.y)
        if isFirstResponder { scrollRangeToVisible(selectedRange) }
      }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      editor?.completeFocusRequestIfAttached()
    }

    override func scrollRangeToVisible(_ range: NSRange) {
      guard !writingToolsOwnsScrolling, markedTextRange == nil else {
        super.scrollRangeToVisible(range)
        return
      }
      layoutDocument()
      reveal(NSMaxRange(range))
    }

    /// TextKit 2's own reveal scrolls to estimated geometry, so long notes stop short of the caret.
    private func reveal(_ offset: Int) {
      guard let position = position(from: beginningOfDocument, offset: offset) else { return }
      let caret = caretRect(for: position).insetBy(dx: 0, dy: -8)
      let viewport = bounds.inset(by: adjustedContentInset)
      guard viewport.height >= caret.height, caret.minY.isFinite, caret.maxY.isFinite else { return }
      if caret.minY < viewport.minY {
        setVerticalContentOffset(contentOffset.y + caret.minY - viewport.minY)
      } else if caret.maxY > viewport.maxY {
        setVerticalContentOffset(contentOffset.y + caret.maxY - viewport.maxY)
      }
    }

    func revealPassage(_ range: NSRange) {
      cancelEditingCaretReveal()
      guard let start = position(from: beginningOfDocument, offset: range.location),
        let end = position(from: start, offset: range.length),
        let passage = textRange(from: start, to: end)
      else { return }
      layoutDocument()
      setNeedsLayout()
      layoutIfNeeded()
      let frame = firstRect(for: passage)
      let height = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
      guard !frame.isEmpty, frame.minY.isFinite, frame.maxY.isFinite, height > 0 else { return }
      let y = frame.height > height ? frame.minY : frame.midY - height / 2
      setVerticalContentOffset(y - adjustedContentInset.top)
      rememberReadingAnchor()
    }

    override var keyCommands: [UIKeyCommand]? {
      let indent = UIKeyCommand(
        input: "]", modifierFlags: .command, action: #selector(increaseIndent))
      indent.discoverabilityTitle = String(localized: "Increase Indent", bundle: .module)
      let outdent = UIKeyCommand(
        input: "[", modifierFlags: .command, action: #selector(decreaseIndent))
      outdent.discoverabilityTitle = String(localized: "Decrease Indent", bundle: .module)
      return (super.keyCommands ?? []) + [indent, outdent]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      switch action {
      case #selector(increaseIndent), #selector(decreaseIndent):
        return editor?.canFormat == true
      case #selector(find(_:)), #selector(findAndReplace(_:)):
        return editor?.isSettled == true && super.canPerformAction(action, withSender: sender)
      default:
        return super.canPerformAction(action, withSender: sender)
      }
    }

    @objc private func increaseIndent() { editor?.indent(outdent: false) }
    @objc private func decreaseIndent() { editor?.indent(outdent: true) }

    func rememberReadingAnchor() {
      guard !writingToolsOwnsScrolling, !restoringAnchor, bounds.width > 0,
        previousWidth == 0 || abs(previousWidth - bounds.width) < 1,
        let position = closestPosition(
          to: CGPoint(x: textContainerInset.left, y: contentOffset.y + adjustedContentInset.top + 1)
        )
      else { return }
      let caret = caretRect(for: position)
      let delta = caret.minY - contentOffset.y
      guard abs(delta - adjustedContentInset.top) <= max(caret.height, 24) * 2 else { return }
      readingOffset = offset(from: beginningOfDocument, to: position)
      anchorDelta = delta
    }

    override func layoutSubviews() {
      editor?.commentHighlights.findVisibilityDidChange()
      applyViewportInsets()
      let needsInitialAnchor = previousWidth == 0
      if writingToolsOwnsScrolling {
        super.layoutSubviews()
        previousWidth = bounds.width
        return
      }

      guard !restoringAnchor else {
        super.layoutSubviews()
        return
      }
      let widthChanged = previousWidth > 0 && abs(previousWidth - bounds.width) > 1
      let heightChanged = previousHeight > 0 && abs(previousHeight - bounds.height) > 1
      let savedOffset = readingOffset
      let savedDelta = anchorDelta
      restoringAnchor = true
      super.layoutSubviews()
      if widthChanged, markedTextRange == nil {
        layoutDocument()
        if !isFirstResponder, let position = position(from: beginningOfDocument, offset: savedOffset) {
          setVerticalContentOffset(caretRect(for: position).minY - savedDelta)
        }
      }
      if widthChanged || heightChanged,
        isFirstResponder, markedTextRange == nil, !isTracking, !isDragging, !isDecelerating
      {
        scrollRangeToVisible(selectedRange)
      }
      previousWidth = bounds.width
      previousHeight = bounds.height
      restoringAnchor = false
      if needsInitialAnchor, bounds.width > 0 {
        layoutDocument()
        rememberReadingAnchor()
      }
      editor?.commentHighlights.layoutBackgrounds()
      editor?.commentHighlights.scrollSelectedCommentIfNeeded()
    }

    /// TextKit 2 estimates the height of text it hasn't laid out, which leaves scroll limits and
    /// offscreen geometry short until the whole note is laid out.
    func layoutDocument() {
      guard let manager = textLayoutManager, let range = manager.textContentManager?.documentRange
      else { return }
      manager.ensureLayout(for: range)
    }

    private func setVerticalContentOffset(_ y: CGFloat) {
      let minimum = -adjustedContentInset.top
      let maximum = max(minimum, contentSize.height - bounds.height + adjustedContentInset.bottom)
      setContentOffset(
        CGPoint(x: contentOffset.x, y: min(maximum, max(minimum, y))), animated: false)
    }
  }
#endif

#if !canImport(UIKit)
  import Foundation
  import Observation

  /// Off iOS the editor is just the note's text, so the library's sync runs in Mac tests. Typing
  /// there is `apply`, which counts a generation and reports the edit as a keystroke does on iOS.
  @MainActor
  @Observable
  public final class Editor: Identifiable {
    public let id = UUID()
    public private(set) var text: String
    public private(set) var generation: UInt64
    public var isEditable = true
    public var isSpellCheckingEnabled = true
    public var isEditing: Bool { false }
    public var isSettled: Bool { true }
    @ObservationIgnored public var onEdit: ((String, UInt64) -> Void)?

    public init(
      text: String, generation: UInt64 = 0, showsFrontMatter: Bool = false
    ) {
      self.text = text
      self.generation = generation
    }

    public func apply(_ edit: Edit, generation: UInt64) throws {
      guard self.generation == generation else { throw Edit.Failure.staleGeneration }
      let result = try edit.applying(to: text)
      guard !result.utf8.elementsEqual(text.utf8) else { return }
      text = result
      self.generation += 1
      onEdit?(text, self.generation)
    }

    public func commitComposition() {}
    public func requestFocusAtEnd() {}
    public func focus() {}
    public func setShowsFrontMatter(_ value: Bool) {}
  }
#endif
