#if canImport(UIKit)
    import Appearance
    import AppIntents
    import Observation
    import UIKit

    /// A note's Markdown source and the text view that edits it. Typing and every applied edit
    /// change the text here, and each change reaches `onEdit` with its generation.
    @Observable
    public final class MarkdownEditor: NSObject, Identifiable {
        public let id = UUID()
        public private(set) var text: String
        public private(set) var generation: UInt64
        private(set) var isComposing = false
        public private(set) var isEditing = false
        private(set) var isWritingToolsActive = false
        private(set) var showsFrontMatter = false
        private(set) var contentStart = 0
        var inputError: String?
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
            textView.installGestures()
            textView.delegate = self
            textView.text = text
            textView.font = .preferredFont(forTextStyle: .body)
            textView.adjustsFontForContentSizeCategory = true
            textView.backgroundColor = .systemBackground
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
            guard isSettled else { throw Edit.Failure.unsettled }
            guard self.generation == generation else { throw Edit.Failure.changed }
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

        /// Shows newer text read from GitHub in a note you can only read, outside Undo and `onEdit`.
        public func reload(_ text: String) {
            self.text = text
            generation += 1
            textView.text = text
            updateHiddenFrontMatter()
            highlight()
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
                inputError = Edit.Failure.unsettled.localizedDescription
                return
            }
            textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
            isFocusPending = true
            completeFocusRequestIfAttached()
        }

        func completeFocusRequestIfAttached() {
            guard isFocusPending, textView.window != nil else { return }
            isFocusPending = false
            textView.becomeFirstResponder()
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        func indent(outdent: Bool) {
            do {
                guard canFormat else { throw Edit.Failure.unsettled }
                if let edit = try Typing.indent(
                    in: text, selection: textView.selectedRange, outdent: outdent)
                {
                    try apply(edit, generation: generation)
                }
            } catch {
                inputError = error.localizedDescription
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
                inputError = error.localizedDescription
                return false
            }
        }

        public func find(replacing: Bool = false) {
            guard isSettled else {
                inputError = Edit.Failure.unsettled.localizedDescription
                return
            }
            commentHighlights.suspendForFind()
            textView.findInteraction?.presentFindNavigator(showingReplace: replacing)
        }

        func highlight() {
            guard isSettled, !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }
            let ink = SyntaxInk(traits: textView.traitCollection)
            textView.updateAttributes { storage in
                ink.paint(in: storage)
                commentHighlights.paint(in: storage)
            }
            textView.typingAttributes = ink.typingAttributes
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

    extension MarkdownEditor: NSTextContentStorageDelegate {
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
    }

    extension MarkdownEditor: UITextViewDelegate {
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
            _ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue],
            replacementText replacement: String
        ) -> Bool {
            let ranges = ranges.map(\.rangeValue)
            guard ranges.allSatisfy({ $0.location >= contentStart }) else { return false }
            // Smart typing reads one selection. UIKit replaces discontiguous ones itself.
            guard ranges.count == 1, canFormat,
                textView.findInteraction?.isFindNavigatorVisible != true
            else { return true }
            if !text.utf8.elementsEqual(textView.text.utf8) { synchronizeText() }
            do {
                guard
                    let edit = try Typing.edit(in: text, selection: ranges[0], replacement: replacement)
                else { return true }
                try apply(edit, generation: generation)
                return false
            } catch {
                inputError = error.localizedDescription
                return false
            }
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
            host?.handBarSource()
        }

        public func textView(
            _ textView: UITextView, editMenuForTextInRanges ranges: [NSValue],
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            commentHighlights.editMenu(ranges: ranges.map(\.rangeValue), suggestedActions: suggestedActions)
        }
    }
#endif

#if !canImport(UIKit)
    import Foundation
    import Observation

    /// Off iOS the editor is just the note's text, so the library's sync runs in Mac tests. Typing
    /// there is `apply`, which counts a generation and reports the edit as a keystroke does on iOS.
    @Observable
    public final class MarkdownEditor: Identifiable {
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
            guard self.generation == generation else { throw Edit.Failure.changed }
            let result = try edit.applying(to: text)
            guard !result.utf8.elementsEqual(text.utf8) else { return }
            text = result
            self.generation += 1
            onEdit?(text, self.generation)
        }

        public func reload(_ text: String) {
            self.text = text
            generation += 1
        }

        public func commitComposition() {}
        public func requestFocusAtEnd() {}
        public func focus() {}
        public func setShowsFrontMatter(_ value: Bool) {}
    }
#endif
