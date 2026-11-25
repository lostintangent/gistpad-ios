#if canImport(UIKit)
    import Appearance
    import AppIntents
    import Comments
    import Markdown
    import Observation
    import UIKit

    /// A note's Markdown document and the text view that edits it. Typing and every applied edit
    /// change the document here, and each change reaches `onEdit` with its generation.
    @Observable
    public final class MarkdownEditor: NSObject, Identifiable {
        public let id = UUID()
        public private(set) var document: MarkdownDocument
        public private(set) var generation: UInt64
        private(set) var isComposing = false
        public private(set) var isEditing = false
        private(set) var isWritingToolsActive = false
        private(set) var showsFrontMatter = false
        private(set) var contentStart = 0
        /// The note's comments, which the editor marks in the text. Nil when the note can't have any.
        @ObservationIgnored var comments: DocumentComments? {
            didSet { if comments != oldValue { commentAnnotator.commentsDidChange(from: oldValue) } }
        }
        /// The threads whose quoted passages the note contains, once it has marked its comments.
        public internal(set) var matchedThreadIDs: Set<Int64>?
        var inputError: Failure?
        let textView = TextView(usingTextLayoutManager: true)
        @ObservationIgnored weak var host: TextViewHost?
        @ObservationIgnored var hosts: [TextViewHost.Reference] = []
        @ObservationIgnored public var onEdit: ((String, UInt64) -> Void)?
        @ObservationIgnored private var isHighlighting = false
        /// The document the text view last highlighted, and how much text at each end no edit has
        /// touched since, so highlighting an edit covers only the blocks it touched.
        @ObservationIgnored private var highlighted: MarkdownDocument?
        @ObservationIgnored private var unedited: (prefix: Int, suffix: Int)?
        /// A caret placed by a focus request, waiting for the text view to reach a window.
        @ObservationIgnored public private(set) var isFocusPending = false
        @ObservationIgnored lazy var commentAnnotator = CommentAnnotator(editor: self)

        public init(
            text: String, generation: UInt64 = 0, showsFrontMatter: Bool = false
        ) {
            document = MarkdownDocument(text)
            self.generation = generation
            self.showsFrontMatter = showsFrontMatter
            super.init()
            textView.editor = self
            textView.installGestures()
            textView.delegate = self
            textView.textStorage.delegate = self
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
                view.editor?.commentAnnotator.accentDidChange()
            }
            updateHiddenFrontMatter()
            textView.selectedRange = NSRange(location: contentStart, length: 0)
            highlight()
        }

        /// Applies one change as an undoable step, while the editor shows the edit's document.
        public func apply(_ edit: MarkdownEdit) throws(Failure) {
            guard isSettled else { throw .unsettled }
            guard edit.document == document else { throw .changed }
            let source = document.text as NSString
            // An edit that changes nothing, like stepping over a closer, only moves the caret.
            guard source.compare(edit.replacement, options: .literal, range: edit.range) != .orderedSame else {
                if let selection = edit.selection { textView.selectedRange = selection }
                return
            }
            let previousSelection = textView.selectedRange
            let replaced = source.substring(with: edit.range)
            let replacement = edit.replacement
            let changed = NSRange(location: edit.range.location, length: replacement.utf16.count)
            let undo = textView.undoManager
            undo?.beginUndoGrouping()
            // Source transactions bypass input substitutions and restore the exact source and selection.
            undo?.disableUndoRegistration()
            textView.textStorage.replaceCharacters(in: edit.range, with: replacement)
            adoptText()
            let delta = replacement.utf16.count - edit.range.length
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
                // Undo puts back what the edit replaced, while the edit's own text is still there.
                let source = editor.document.text as NSString
                guard NSMaxRange(changed) <= source.length,
                    source.compare(replacement, options: .literal, range: changed) == .orderedSame
                else { return editor.inputError = .changed }
                editor.perform(editor.document.edit(replacing: changed, with: replaced, selection: previousSelection))
            }
            undo?.endUndoGrouping()
            synchronizeText()
            if let selection = edit.selection { textView.scrollRangeToVisible(selection) }
        }

        /// Applies an edit made from the current document, or shows why it can't land.
        @discardableResult
        func perform(_ edit: MarkdownEdit?) -> Bool {
            guard let edit else { return false }
            do {
                try apply(edit)
                return true
            } catch {
                inputError = error
                return false
            }
        }

        /// Shows newer text read from GitHub in a note you can only read, outside Undo and `onEdit`.
        public func reload(_ text: String) {
            document = MarkdownDocument(text)
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
            textView.becomeFirstResponder()
        }

        /// Keeps what the keyboard is composing as typed text, as leaving a note does in Notes.
        public func commitComposition() {
            guard textView.markedTextRange != nil else { return }
            textView.unmarkText()
            synchronizeText()
        }

        /// Puts the caret at the end, ready to write, as a new gist or today's note opens.
        public func requestFocusAtEnd() {
            guard canFormat else { return inputError = .unsettled }
            textView.selectedRange = NSRange(location: document.text.utf16.count, length: 0)
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
            guard canFormat else { return inputError = .unsettled }
            let selection = textView.selectedRange
            perform(outdent ? document.edit(outdenting: selection) : document.edit(indenting: selection))
        }

        func indentSwipedLine(at point: CGPoint, outdent: Bool) -> Bool {
            guard canFormat, textView.findInteraction?.isFindNavigatorVisible != true,
                let position = textView.closestPosition(to: point)
            else { return false }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard document.isListItem(at: offset) else { return false }
            let line = NSRange(location: offset, length: 0)
            let kept = textView.selectedRange
            let edit =
                outdent
                ? document.edit(outdenting: line, keeping: kept) : document.edit(indenting: line, keeping: kept)
            guard perform(edit) else { return false }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }

        public func find(replacing: Bool = false) {
            guard isSettled else { return inputError = .unsettled }
            commentAnnotator.suspendForFind()
            textView.findInteraction?.presentFindNavigator(showingReplace: replacing)
        }

        /// Highlights the whole note, as a change to its look or its comments needs.
        func highlight() {
            highlighted = nil
            highlightEdits()
        }

        /// Highlights what the edits since the last highlight touched. A quoted passage can match
        /// anywhere after an edit, so a note with quotes highlights whole.
        private func highlightEdits() {
            guard isSettled, !isHighlighting else { return }
            let document = shownDocument
            var range = document.range
            if let highlighted, commentAnnotator.quotes.isEmpty {
                guard let unedited else { return }
                let edited = NSRange(unedited.prefix..<(range.length - unedited.suffix))
                range = document.spanRange(for: edited, from: highlighted)
            }
            isHighlighting = true
            defer { isHighlighting = false }
            let style = MarkdownStyle(traits: textView.traitCollection)
            textView.updateAttributes(in: range) { storage in
                style.apply(document.spans(in: range), to: storage, in: range)
                commentAnnotator.annotate(storage)
            }
            textView.typingAttributes = style.typingAttributes
            highlighted = document
            unedited = nil
        }

        private func synchronizeText() {
            // Inline previews are transient. UIKit owns their selection and native undo history.
            guard !isWritingToolsActive else { return }
            isComposing = textView.markedTextRange != nil
            adoptText()
            highlightEdits()
        }

        /// Makes the text view's text the document, counting each change once.
        @discardableResult
        private func adoptText() -> Bool {
            let text: String = textView.text
            guard !(document.text as NSString).isEqual(to: text) else { return false }
            document = MarkdownDocument(text)
            updateHiddenFrontMatter()
            generation += 1
            textView.requestEditingCaretReveal()
            onEdit?(document.text, generation)
            return true
        }

        /// The document for the text on screen. UIKit changes the text before it reports the change,
        /// and Writing Tools previews text the document takes only when it ends.
        private var shownDocument: MarkdownDocument {
            let text: String = textView.text
            return (document.text as NSString).isEqual(to: text) ? document : MarkdownDocument(text)
        }
    }

    extension MarkdownEditor: NSTextContentStorageDelegate {
        /// Shows or hides the note's front matter, keeping what the keyboard is composing.
        public func setShowsFrontMatter(_ value: Bool) {
            guard value != showsFrontMatter else { return }
            commitComposition()
            showsFrontMatter = value
            updateHiddenFrontMatter()
            commentAnnotator.frontMatterVisibilityDidChange()
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
            let start = showsFrontMatter ? 0 : document.contentStart
            textView.accessibilityValue = start > 0 ? document.body : nil
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

    extension MarkdownEditor: NSTextStorageDelegate {
        public func textStorage(
            _ storage: NSTextStorage, didProcessEditing actions: NSTextStorage.EditActions, range: NSRange,
            changeInLength _: Int
        ) {
            guard actions.contains(.editedCharacters) else { return }
            // Each edit leaves the text before and after its range alone, so the shortest of each holds.
            let suffix = storage.length - NSMaxRange(range)
            unedited = (min(unedited?.prefix ?? .max, range.location), min(unedited?.suffix ?? .max, suffix))
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
            if adoptText() { highlightEdits() }
            guard let edit = document.edit(typing: replacement, over: ranges[0]) else { return true }
            perform(edit)
            return false
        }

        public func textViewDidChangeSelection(_: UITextView) {
            // Re-setting runs the selection setter's clamp on selections UIKit makes itself.
            if textView.selectedRange.location < min(contentStart, textView.text.utf16.count) {
                textView.selectedRange = textView.selectedRange
            }
            isComposing = textView.markedTextRange != nil
            if isComposing { textView.cancelEditingCaretReveal() }
            commentAnnotator.selectionDidChange()
        }

        public func textViewWritingToolsWillBegin(_: UITextView) {
            synchronizeText()
            commentAnnotator.suspendForWritingTools()
            isWritingToolsActive = true
            textView.cancelEditingCaretReveal()
        }

        public func textViewWritingToolsDidEnd(_: UITextView) {
            isWritingToolsActive = false
            commentAnnotator.resumeAfterWritingTools()
            synchronizeText()
            textView.rememberReadingAnchor()
        }

        public func textView(
            _ textView: UITextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
        ) -> [NSValue] {
            var ranges = shownDocument.protectedRanges(in: enclosingRange)
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
            commentAnnotator.editMenu(ranges: ranges.map(\.rangeValue), suggestedActions: suggestedActions)
        }
    }
#endif

#if !canImport(UIKit)
    import Foundation
    import Markdown
    import Observation

    /// Off iOS the editor is just the note's document, so the library's sync runs in Mac tests. Typing
    /// there is `apply`, which counts a generation and reports the edit as a keystroke does on iOS.
    @Observable
    public final class MarkdownEditor: Identifiable {
        public let id = UUID()
        public private(set) var document: MarkdownDocument
        public private(set) var generation: UInt64
        public var isEditable = true
        public var isSpellCheckingEnabled = true
        public var isEditing: Bool { false }
        public var isSettled: Bool { true }
        @ObservationIgnored public var onEdit: ((String, UInt64) -> Void)?

        public init(
            text: String, generation: UInt64 = 0, showsFrontMatter: Bool = false
        ) {
            document = MarkdownDocument(text)
            self.generation = generation
        }

        public func apply(_ edit: MarkdownEdit) throws(Failure) {
            guard edit.document == document else { throw .changed }
            let result = MarkdownDocument(edit.result)
            guard result != document else { return }
            document = result
            generation += 1
            onEdit?(document.text, generation)
        }

        public func reload(_ text: String) {
            document = MarkdownDocument(text)
            generation += 1
        }

        public func commitComposition() {}
        public func requestFocusAtEnd() {}
        public func focus() {}
        public func setShowsFrontMatter(_ value: Bool) {}
    }
#endif

extension MarkdownEditor {
    /// Why an edit can't land in the editor, in one sentence.
    public enum Failure: Error, Equatable {
        /// The keyboard is composing or Writing Tools is working, so the editor isn't settled.
        case unsettled
        /// The text changed since the edit was made, so it no longer fits.
        case changed
        case invalidLink
    }
}

extension MarkdownEditor.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsettled:
            String(localized: "Finish typing or wait for Writing Tools, then try again.", bundle: .module)
        case .changed:
            String(localized: "This file changed. Select the text again.", bundle: .module)
        case .invalidLink:
            String(localized: "Enter a complete web, email or phone link.", bundle: .module)
        }
    }
}
