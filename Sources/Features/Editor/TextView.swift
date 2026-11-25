#if canImport(UIKit)
    import Accessibility
    import UIKit

    /// The source's text view. It fills the platform gaps a Markdown source runs into: hidden front
    /// matter, precise taps, the keyboard's inset, the caret's reveal and the passage being read.
    final class TextView: UITextView, AXCustomContentProvider, UIGestureRecognizerDelegate {
        var accessibilityCustomContent: [AXCustomContent]! = []
        private enum AttributeUpdateAnchor {
            case reading(offset: Int, delta: CGFloat)
            case caret
        }

        weak var editor: MarkdownEditor?
        /// Writing Tools owns inline animations and scrolling until its session finishes.
        private var writingToolsOwnsScrolling: Bool { editor?.isWritingToolsActive == true }
        private var contentStart: Int { editor?.contentStart ?? 0 }
        private var previousWidth: CGFloat = 0
        private var previousHeight: CGFloat = 0
        private var readingOffset = 0
        private var anchorDelta: CGFloat = 0
        private var restoringAnchor = false
        private var needsEditingCaretReveal = false
        /// How far the keyboard and its bar reach into the view, from its host's keyboard guide.
        var keyboardOverlap: CGFloat = 0 {
            didSet { if abs(keyboardOverlap - oldValue) > 0.001 { setNeedsLayout() } }
        }

        // Platform gap: UIKit still selects and deletes text that shouldEnumerate hides, so this
        // setter and deleteBackward stop at hidden front matter. Remove both when it can't be selected.
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

        func installGestures() {
            for direction in [UISwipeGestureRecognizer.Direction.right, .left] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleIndentSwipe))
                swipe.direction = direction
                swipe.delegate = self
                addGestureRecognizer(swipe)
            }
            addGestureRecognizer(FingerTap(target: nil, action: nil))
        }

        /// Whether a finger tap is landing, from touch-down until the system has handled it.
        var isLandingTap = false

        // Platform gap: a finger tap snaps the caret to the edge of the word under it, and no API sets
        // the tap's granularity. While a tap lands, the tokenizer answers that every position is a word
        // edge, so the system's own tap places the caret at the character under the finger and keeps
        // its caret menu, misspelling suggestions and double tap. Remove the override, FingerTap and
        // TapTokenizer when UIKit places taps precisely.
        override var tokenizer: any UITextInputTokenizer {
            isLandingTap ? TapTokenizer(base: super.tokenizer) : super.tokenizer
        }

        /// Watches a finger tap without acting on it or holding up any other gesture.
        private final class FingerTap: UITapGestureRecognizer {
            override init(target: Any?, action: Selector?) {
                super.init(target: target, action: action)
                allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
                cancelsTouchesInView = false
                delaysTouchesEnded = false
            }

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
                super.touchesBegan(touches, with: event)
                guard let view = view as? TextView, view.markedTextRange == nil, !view.isWritingToolsActive
                else { return }
                view.isLandingTap = true
            }

            override func reset() {
                super.reset()
                (view as? TextView)?.isLandingTap = false
            }

            override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
            override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }
        }

        private final class TapTokenizer: NSObject, UITextInputTokenizer {
            let base: any UITextInputTokenizer

            init(base: any UITextInputTokenizer) {
                self.base = base
            }

            func isPosition(
                _ position: UITextPosition, atBoundary granularity: UITextGranularity,
                inDirection direction: UITextDirection
            ) -> Bool {
                granularity == .word
                    || base.isPosition(position, atBoundary: granularity, inDirection: direction)
            }

            func isPosition(
                _ position: UITextPosition, withinTextUnit granularity: UITextGranularity,
                inDirection direction: UITextDirection
            ) -> Bool {
                granularity != .word
                    && base.isPosition(position, withinTextUnit: granularity, inDirection: direction)
            }

            func rangeEnclosingPosition(
                _ position: UITextPosition, with granularity: UITextGranularity,
                inDirection direction: UITextDirection
            ) -> UITextRange? {
                base.rangeEnclosingPosition(position, with: granularity, inDirection: direction)
            }

            func position(
                from position: UITextPosition, toBoundary granularity: UITextGranularity,
                inDirection direction: UITextDirection
            ) -> UITextPosition? {
                base.position(from: position, toBoundary: granularity, inDirection: direction)
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

        /// Updates the attributes of `range` in `update` without touching its characters, selection
        /// or Undo, and keeps the caret or the passage being read where it was.
        func updateAttributes(in range: NSRange, _ update: (NSTextStorage) -> Void) {
            let anchor = beginAttributeUpdate()
            defer { endAttributeUpdate(anchor) }
            // While the caret is on screen, the style lands on a copy and only the runs that change
            // reach the text view, so TextKit lays out only what changed.
            let storage = if case .caret? = anchor { NSTextStorage(string: text) } else { textStorage }
            let selection = selectedRange
            let undo = undoManager
            undo?.disableUndoRegistration()
            storage.beginEditing()
            update(storage)
            storage.endEditing()
            if storage !== textStorage { applyChangedAttributes(of: storage, in: range) }
            undo?.enableUndoRegistration()
            if selectedRange != selection { selectedRange = selection }
        }

        private func applyChangedAttributes(of updated: NSAttributedString, in range: NSRange) {
            let storage = textStorage
            storage.beginEditing()
            updated.enumerateAttributes(in: range) {
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

        private func beginAttributeUpdate() -> AttributeUpdateAnchor? {
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

        private func endAttributeUpdate(_ anchor: AttributeUpdateAnchor?) {
            guard let anchor else { return }
            defer { restoringAnchor = false }
            switch anchor {
            case .reading(let offset, let delta):
                // Attribute invalidation can replace exact offscreen geometry with TextKit estimates.
                layoutDocument()
                // UITextView scrolls to the selection on its next layout after an edit, so lay out here,
                // where the reading anchor then wins.
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

        // Platform gap: UIKit insets the source below the bars but not above the keyboard and its
        // bar, so the source insets for its keyboard overlap. Remove when UIScrollView insets for both.
        private func applyKeyboardInset() {
            guard window != nil else { return }
            let automatic = adjustedContentInset.bottom - contentInset.bottom
            let bottom = max(0, keyboardOverlap - automatic)
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

        // Platform gap: TextKit 2's own reveal scrolls to estimated geometry, so long notes stop short
        // of the caret. Remove this override and reveal(_:) when UITextView reveals laid-out text.
        override func scrollRangeToVisible(_ range: NSRange) {
            guard !writingToolsOwnsScrolling, markedTextRange == nil else {
                super.scrollRangeToVisible(range)
                return
            }
            layoutDocument()
            reveal(NSMaxRange(range))
        }

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

        // Platform gap: through a reflow from a new width or new attributes, UITextView keeps its
        // scroll offset, not the passage on screen. Remove the reading anchor when it anchors to text.
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
            editor?.commentAnnotator.findVisibilityDidChange()
            applyKeyboardInset()
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
            editor?.commentAnnotator.layoutBackgrounds()
            editor?.commentAnnotator.scrollSelectedCommentIfNeeded()
        }

        // Platform gap: TextKit 2 estimates the height of text it hasn't laid out, which leaves scroll
        // limits and offscreen geometry short. Remove when UITextView keeps them exact as it lays out.
        func layoutDocument() {
            guard let manager = textLayoutManager, let range = manager.textContentManager?.documentRange
            else { return }
            manager.ensureLayout(for: range)
            // UITextView takes the exact height as its content size only when the viewport lays out.
            manager.textViewportLayoutController.layoutViewport()
        }

        private func setVerticalContentOffset(_ y: CGFloat) {
            let minimum = -adjustedContentInset.top
            let maximum = max(minimum, contentSize.height - bounds.height + adjustedContentInset.bottom)
            setContentOffset(
                CGPoint(x: contentOffset.x, y: min(maximum, max(minimum, y))), animated: false)
        }
    }
#endif
