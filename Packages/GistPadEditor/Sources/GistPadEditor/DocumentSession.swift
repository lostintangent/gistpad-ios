#if canImport(UIKit)
  import GistPadInterface
  import Observation
  import SwiftUI
  import UIKit

  @MainActor
  @Observable
  public final class DocumentSession: NSObject, UITextViewDelegate {
    public let documentID: String
    public let viewIdentity = UUID()
    public private(set) var text: String
    public private(set) var generation: UInt64
    public private(set) var selection = NSRange(location: 0, length: 0)
    public private(set) var isComposing = false
    public private(set) var isEditing = false
    public private(set) var writingToolsActive = false
    public var inputError: String?
    @ObservationIgnored public let textView: UITextView
    @ObservationIgnored public var onSourceChange: ((String, UInt64) -> Void)?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var highlightedTraits: UITraitCollection?
    @ObservationIgnored private var isApplyingSourceEdit = false
    @ObservationIgnored private var pendingFocusAtEnd = false

    public init(documentID: String, text: String, generation: UInt64 = 0) {
      self.documentID = documentID
      self.text = text
      self.generation = generation
      textView = AnchoredTextView(usingTextLayoutManager: true)
      super.init()
      textView.delegate = self
      textView.text = text
      textView.font = .preferredFont(forTextStyle: .body)
      textView.adjustsFontForContentSizeCategory = true
      textView.backgroundColor = .systemBackground
      textView.tintColor = UIColor(InterfaceTheme.accent)
      textView.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 40, right: 20)
      textView.alwaysBounceVertical = true
      textView.topEdgeEffect.style = .soft
      textView.bottomEdgeEffect.style = .soft
      textView.isFindInteractionEnabled = true
      textView.accessibilityIdentifier = "source-editor"
      textView.accessibilityLabel = "Markdown source"
      textView.smartQuotesType = .no
      textView.smartDashesType = .no
      textView.writingToolsBehavior = .complete
      textView.allowedWritingToolsResultOptions = .plainText
      textView.registerForTraitChanges([
        UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self,
        UITraitAccessibilityContrast.self, UITraitLegibilityWeight.self,
      ]) { (view: UITextView, _: UITraitCollection) in
        (view.delegate as? DocumentSession)?.updateAppearanceIfNeeded()
      }
      highlight()
    }

    public func apply(_ mutation: SourceMutation, documentID: String, generation: UInt64) throws {
      try apply(mutation, documentID: documentID, generation: generation, finalSelection: nil)
    }

    private func apply(
      _ mutation: SourceMutation, documentID: String, generation: UInt64, finalSelection: NSRange?
    ) throws {
      guard self.documentID == documentID else {
        throw SourceMutation.MutationError.documentMismatch
      }
      guard self.generation == generation else {
        throw SourceMutation.MutationError.staleGeneration
      }
      guard textView.markedTextRange == nil && !writingToolsActive else {
        throw SourceMutation.MutationError.compositionActive
      }
      _ = try mutation.applying(to: text)
      let previousSelection = textView.selectedRange
      guard
        let start = textView.position(
          from: textView.beginningOfDocument, offset: mutation.range.location),
        let end = textView.position(from: start, offset: mutation.range.length),
        let range = textView.textRange(from: start, to: end)
      else {
        throw SourceMutation.MutationError.invalidRange
      }
      isApplyingSourceEdit = true
      textView.undoManager?.beginUndoGrouping()
      textView.replace(range, withText: mutation.replacement)
      let delta = mutation.replacement.utf16.count - mutation.range.length
      if let finalSelection {
        textView.selectedRange = finalSelection
      } else if NSMaxRange(previousSelection) <= mutation.range.location {
        textView.selectedRange = previousSelection
      } else if previousSelection.location >= NSMaxRange(mutation.range) {
        textView.selectedRange = NSRange(
          location: previousSelection.location + delta, length: previousSelection.length)
      }
      textView.undoManager?.endUndoGrouping()
      isApplyingSourceEdit = false
      synchronizeText()
    }

    public var canFormat: Bool {
      textView.isEditable && textView.markedTextRange == nil && !isComposing && !writingToolsActive
    }

    public func requestFocusAtEnd() {
      guard canFormat else {
        inputError = String(
          localized: "Finish the current text edit before moving the caret.", bundle: .module)
        return
      }
      selection = NSRange(location: text.utf16.count, length: 0)
      textView.selectedRange = selection
      pendingFocusAtEnd = true
      completeFocusRequestIfAttached()
    }

    fileprivate func completeFocusRequestIfAttached() {
      guard pendingFocusAtEnd, textView.window != nil else { return }
      pendingFocusAtEnd = false
      guard canFormat, textView.becomeFirstResponder() else {
        inputError = String(
          localized: "The editor couldn't receive focus. Tap the note to start writing.",
          bundle: .module)
        return
      }
      textView.scrollRangeToVisible(textView.selectedRange)
    }

    func updateViewportInsets(_ insets: UIEdgeInsets) {
      guard let view = textView as? AnchoredTextView else {
        preconditionFailure("Document sessions require the retained source text view.")
      }
      view.updateViewportInsets(insets)
    }

    public func apply(_ edit: SourceEdit, generation: UInt64) throws {
      guard canFormat else { throw SourceMutation.MutationError.compositionActive }
      guard self.generation == generation else {
        throw SourceMutation.MutationError.staleGeneration
      }
      let result = try edit.mutation.applying(to: text)
      guard edit.selection.location >= 0, edit.selection.length >= 0,
        edit.selection.location <= result.utf16.count,
        edit.selection.length <= result.utf16.count - edit.selection.location,
        Range(edit.selection, in: result) != nil
      else { throw SourceMutation.MutationError.invalidRange }
      try apply(
        edit.mutation, documentID: documentID, generation: generation,
        finalSelection: edit.selection)
      textView.scrollRangeToVisible(edit.selection)
    }

    public func textViewDidBeginEditing(_ textView: UITextView) { isEditing = true }

    public func textViewDidEndEditing(_ textView: UITextView) {
      isEditing = false
      synchronizeText()
    }

    public func textViewDidChange(_ textView: UITextView) {
      synchronizeText()
    }

    public func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String
    ) -> Bool {
      guard !isApplyingSourceEdit, !writingToolsActive, textView.isEditable,
        textView.markedTextRange == nil, !isComposing,
        textView.findInteraction?.isFindNavigatorVisible != true
      else { return true }
      synchronizeText()
      do {
        guard
          let edit = try MarkdownTyping.edit(
            in: text, selection: range, replacement: replacement, isComposing: isComposing)
        else { return true }
        try apply(edit, generation: generation)
        return false
      } catch {
        inputError = String(
          localized: "The source changed before this edit could be applied. Select the text again.",
          bundle: .module)
        return false
      }
    }

    public func indent(outdent: Bool) throws {
      guard canFormat else { throw SourceMutation.MutationError.compositionActive }
      if let edit = try MarkdownTyping.indent(
        in: text, selection: textView.selectedRange, outdent: outdent)
      {
        try apply(edit, generation: generation)
      }
    }

    var canFind: Bool {
      !writingToolsActive && !isComposing && textView.markedTextRange == nil
    }

    public func presentFind(replacing: Bool = false) {
      guard canFind else {
        inputError = String(
          localized: "Finish the current text edit before finding text.", bundle: .module)
        return
      }
      guard let interaction = textView.findInteraction else {
        inputError = String(localized: "Find is unavailable in this editor.", bundle: .module)
        return
      }
      textView.becomeFirstResponder()
      interaction.presentFindNavigator(showingReplace: replacing)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
      selection = textView.selectedRange
      isComposing = textView.markedTextRange != nil
      if !isComposing { scheduleHighlight() }
    }

    public func textViewWritingToolsWillBegin(_ textView: UITextView) {
      synchronizeText()
      writingToolsActive = true
      highlightTask?.cancel()
      (textView as? AnchoredTextView)?.sourceInteractionActive = true
    }

    public func textViewWritingToolsDidEnd(_ textView: UITextView) {
      writingToolsActive = false
      synchronizeText()
      (textView as? AnchoredTextView)?.sourceInteractionActive = false
      (textView as? AnchoredTextView)?.rememberReadingAnchor()
    }

    public func textView(
      _ textView: UITextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
    ) -> [NSValue] {
      MarkdownSyntax.ignoredWritingToolsRanges(in: textView.text, enclosing: enclosingRange).map(
        NSValue.init(range:))
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
      (textView as? AnchoredTextView)?.rememberReadingAnchor()
    }

    public func highlight() {
      guard textView.markedTextRange == nil && !writingToolsActive else { return }
      let storage = textView.textStorage
      let bodyFont = UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: textView.traitCollection)
      let boldText = textView.traitCollection.legibilityWeight == .bold
      let headingFont = UIFont.systemFont(
        ofSize: bodyFont.pointSize, weight: .bold)
      let codeFont = UIFont.monospacedSystemFont(
        ofSize: bodyFont.pointSize, weight: boldText ? .semibold : .regular)
      let muted = UIColor(InterfaceTheme.syntaxMuted)
      let selectedRange = textView.selectedRange
      let manager = textView.undoManager
      let undoWasEnabled = manager?.isUndoRegistrationEnabled == true
      if undoWasEnabled { manager?.disableUndoRegistration() }
      storage.beginEditing()
      storage.setAttributes(
        [
          .font: bodyFont,
          .foregroundColor: UIColor(InterfaceTheme.text),
        ], range: NSRange(location: 0, length: storage.length))
      for span in MarkdownSyntax.spans(in: textView.text) {
        let attributes: [NSAttributedString.Key: Any]
        switch span.kind {
        case .heading:
          attributes = [.foregroundColor: SourceSyntaxColor.emphasis, .font: headingFont]
        case .strong, .emphasis:
          attributes = [.foregroundColor: SourceSyntaxColor.emphasis]
        case .blockquote:
          attributes = [.foregroundColor: SourceSyntaxColor.quote]
        case .htmlTag:
          attributes = [.foregroundColor: SourceSyntaxColor.htmlTag]
        case .strikethrough:
          attributes = [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .orderedMarker:
          attributes = [.foregroundColor: SourceSyntaxColor.orderedMarker]
        case .code:
          attributes = [
            .foregroundColor: UIColor(InterfaceTheme.text),
            .font: codeFont,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
          ]
        case .frontmatter:
          attributes = [.foregroundColor: UIColor(InterfaceTheme.text), .font: codeFont]
        case .link:
          attributes = [
            .foregroundColor: SourceSyntaxColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ]
        case .linkDestination:
          attributes = [
            .foregroundColor: SourceSyntaxColor.destination,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ]
        case .task:
          attributes = [.foregroundColor: UIColor(InterfaceTheme.accent)]
        case .checkedTask:
          attributes = [.foregroundColor: muted]
        case .punctuation:
          attributes = [:]
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
      storage.endEditing()
      if undoWasEnabled { manager?.enableUndoRegistration() }
      if textView.selectedRange != selectedRange {
        textView.selectedRange = selectedRange
      }
      textView.typingAttributes = [
        .font: bodyFont,
        .foregroundColor: UIColor(InterfaceTheme.text),
      ]
      highlightedTraits = textView.traitCollection
    }

    public func updateAppearanceIfNeeded() {
      if highlightedTraits?.preferredContentSizeCategory
        != textView.traitCollection.preferredContentSizeCategory
        || highlightedTraits?.legibilityWeight != textView.traitCollection.legibilityWeight
      {
        highlight()
      } else {
        highlightedTraits = textView.traitCollection
      }
    }

    private func synchronizeText() {
      // Inline previews are transient. UIKit owns their selection and native undo history.
      guard !writingToolsActive && !isApplyingSourceEdit else { return }
      selection = textView.selectedRange
      isComposing = textView.markedTextRange != nil
      if !text.utf8.elementsEqual(textView.text.utf8) {
        text = textView.text
        generation += 1
        onSourceChange?(text, generation)
      }
      scheduleHighlight()
    }

    private func scheduleHighlight() {
      highlightTask?.cancel()
      guard !isComposing && !writingToolsActive else { return }
      highlightTask = Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(100))
        } catch is CancellationError {
          return
        } catch {
          assertionFailure("Unexpected highlighting delay failure: \(error)")
          return
        }
        self?.highlight()
      }
    }
  }

  private final class AnchoredTextView: UITextView {
    var sourceInteractionActive = false
    private var previousWidth: CGFloat = 0
    private var readingOffset = 0
    private var anchorDelta: CGFloat = 0
    private var restoringAnchor = false
    private var viewportInsets: UIEdgeInsets?
    private var applyingViewportInsets = false

    func updateViewportInsets(_ insets: UIEdgeInsets) {
      viewportInsets = insets
      applyViewportInsets()
    }

    override func adjustedContentInsetDidChange() {
      super.adjustedContentInsetDidChange()
      applyViewportInsets()
    }

    private func applyViewportInsets() {
      guard !applyingViewportInsets, let viewportInsets else { return }
      let previous = adjustedContentInset
      var insets = contentInset
      insets.top = max(0, viewportInsets.top - (previous.top - contentInset.top))
      insets.bottom = max(0, viewportInsets.bottom - (previous.bottom - contentInset.bottom))
      guard
        abs(insets.top - contentInset.top) > 0.001
          || abs(insets.bottom - contentInset.bottom) > 0.001
      else { return }
      applyingViewportInsets = true
      let wasRestoring = restoringAnchor
      restoringAnchor = true
      defer {
        restoringAnchor = wasRestoring
        applyingViewportInsets = false
      }
      let offset = contentOffset
      contentInset = insets
      verticalScrollIndicatorInsets.top = insets.top
      verticalScrollIndicatorInsets.bottom = insets.bottom
      if !sourceInteractionActive, markedTextRange == nil, !isTracking, !isDecelerating {
        setVerticalContentOffset(offset.y + previous.top - adjustedContentInset.top)
        if isFirstResponder { scrollRangeToVisible(selectedRange) }
      }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      (delegate as? DocumentSession)?.completeFocusRequestIfAttached()
    }

    override var keyCommands: [UIKeyCommand]? {
      let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findText))
      find.discoverabilityTitle = String(localized: "Find", bundle: .module)
      let indent = UIKeyCommand(
        input: "]", modifierFlags: .command, action: #selector(increaseIndent))
      indent.discoverabilityTitle = String(localized: "Increase Indent", bundle: .module)
      let outdent = UIKeyCommand(
        input: "[", modifierFlags: .command, action: #selector(decreaseIndent))
      outdent.discoverabilityTitle = String(localized: "Decrease Indent", bundle: .module)
      let inherited = (super.keyCommands ?? []).filter {
        !($0.input == "f" && $0.modifierFlags == .command)
      }
      return inherited + [find, indent, outdent]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      if action == #selector(findText) {
        return (delegate as? DocumentSession)?.canFind == true
      }
      if action == #selector(increaseIndent) || action == #selector(decreaseIndent) {
        return (delegate as? DocumentSession)?.canFormat == true
      }
      return super.canPerformAction(action, withSender: sender)
    }

    @objc private func increaseIndent() { changeIndent(outdent: false) }
    @objc private func decreaseIndent() { changeIndent(outdent: true) }
    @objc private func findText() { (delegate as? DocumentSession)?.presentFind() }

    private func changeIndent(outdent: Bool) {
      guard let session = delegate as? DocumentSession else { return }
      do {
        try session.indent(outdent: outdent)
      } catch {
        session.inputError = String(
          localized: "Finish the current text edit, then select the lines again.", bundle: .module)
      }
    }

    func rememberReadingAnchor() {
      guard !sourceInteractionActive, !restoringAnchor, bounds.width > 0,
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
      applyViewportInsets()
      if sourceInteractionActive {
        // Writing Tools owns inline animations and scrolling until its session finishes.
        super.layoutSubviews()
        previousWidth = bounds.width
        return
      }
      guard !restoringAnchor else {
        super.layoutSubviews()
        return
      }
      let widthChanged = previousWidth > 0 && abs(previousWidth - bounds.width) > 1
      let savedOffset = readingOffset
      let savedDelta = anchorDelta
      restoringAnchor = true
      super.layoutSubviews()
      if widthChanged, markedTextRange == nil {
        if let manager = textLayoutManager, let range = manager.textContentManager?.documentRange {
          manager.ensureLayout(for: range)
        }
        if isFirstResponder {
          scrollRangeToVisible(selectedRange)
        } else if let position = position(from: beginningOfDocument, offset: savedOffset) {
          scrollRangeToVisible(NSRange(location: savedOffset, length: 0))
          super.layoutSubviews()
          let y = caretRect(for: position).minY - savedDelta
          setVerticalContentOffset(y)
        }
      }
      previousWidth = bounds.width
      restoringAnchor = false
      rememberReadingAnchor()
    }

    private func setVerticalContentOffset(_ y: CGFloat) {
      let minimum = -adjustedContentInset.top
      let maximum = max(minimum, contentSize.height - bounds.height + adjustedContentInset.bottom)
      setContentOffset(
        CGPoint(x: contentOffset.x, y: min(maximum, max(minimum, y))), animated: false)
    }
  }
#endif
