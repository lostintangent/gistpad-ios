#if canImport(UIKit)
    import Accessibility
    import Appearance
    import Comments
    import Markdown
    import UIKit

    final class CommentAnnotator: NSObject, UIGestureRecognizerDelegate {
        static let annotationKey = NSAttributedString.Key("dev.gistpad.comment.annotation")
        private unowned let editor: MarkdownEditor
        let backgroundLayer = CALayer()
        var openThreads: @MainActor ([Int64]) -> Void = { _ in }
        var addComment: @MainActor (String) -> Void = { _ in }
        private var matchedIDs: Set<Int64>?
        private var passages: [(annotation: CommentQuote.Match, fill: UIColor, selected: Bool)] = []
        private var verifiedAnnotations: [CommentQuote.Match] = []
        private var originalInk: [(range: NSRange, color: Any)] = []
        private var annotatedGeneration: UInt64?
        private var suspendsForFind = false
        private var suspendsForWritingTools = false
        private var isSuspended: Bool { suspendsForFind || suspendsForWritingTools }
        private var updatingSelection = false
        private var pendingTap: [Int64]?
        private(set) var pendingFindUpdate: Task<Void, Never>?
        private(set) var publication: Task<Void, Never>?
        private(set) var scrollTask: Task<Void, Never>?
        private var pendingReveal: Int64?
        private var onSelected = UIColor.label
        private lazy var tap = UITapGestureRecognizer(
            target: self, action: #selector(openTappedPassage))
        private lazy var selectionTap = UITapGestureRecognizer(
            target: self, action: #selector(selectTappedWord))

        init(editor: MarkdownEditor) {
            self.editor = editor
            super.init()
            editor.textView.layer.insertSublayer(backgroundLayer, at: 0)
            tap.delegate = self
            selectionTap.numberOfTapsRequired = 2
            selectionTap.cancelsTouchesInView = false
            selectionTap.delaysTouchesBegan = false
            selectionTap.delaysTouchesEnded = false
            selectionTap.delegate = self
            tap.require(toFail: selectionTap)
            editor.textView.addGestureRecognizer(selectionTap)
            editor.textView.addGestureRecognizer(tap)
        }

        var quotes: [CommentQuote] { editor.comments?.quotes ?? [] }

        func commentsDidChange(from old: DocumentComments?) {
            // A note without quoted passages looks the same with or without comments.
            if old?.quotes.isEmpty == false || !quotes.isEmpty { editor.highlight() }
        }

        func reveal(_ threadID: Int64) {
            pendingReveal = threadID
            scrollTask?.cancel()
            scrollTask = nil
            revealPendingThread()
        }

        func annotate(_ storage: NSTextStorage) {
            passages = []
            originalInk = []
            annotatedGeneration = editor.generation
            editor.textView.setNeedsLayout()
            let annotations = quotes.matches(in: [editor.document.text])
                .filter { $0.start >= editor.contentStart }
            verifiedAnnotations = annotations
            publish(editor.comments.map { _ in Set(annotations.flatMap(\.threadIDs)) })
            updateAccessibility()
            guard let comments = editor.comments, !annotations.isEmpty, !isSuspended else {
                backgroundLayer.sublayers = nil
                return
            }
            let traits = editor.textView.traitCollection
            let accent = traits[AccentTrait.self]
            let roles = accent.roles(traits: traits)
            onSelected = roles.onFill.uiColor
            let page = RGBColor(uiColor: UIColor.systemBackground.resolvedColor(with: traits))
            for annotation in annotations {
                let selected = comments.selectedThreadID.map(annotation.threadIDs.contains) ?? false
                guard comments.showsAll || selected else { continue }
                let fill: UIColor
                if selected {
                    fill = roles.fill.uiColor
                    storage.enumerateAttribute(.foregroundColor, in: annotation.range) { color, range, _ in
                        originalInk.append((range, color ?? UIColor.label))
                    }
                } else {
                    var inks: [(RGBColor, Double)] = []
                    storage.enumerateAttribute(.foregroundColor, in: annotation.range) { value, _, _ in
                        let color = (value as? UIColor ?? .label).resolvedColor(with: traits)
                        inks.append((RGBColor(uiColor: color.withAlphaComponent(1)), Double(color.cgColor.alpha)))
                    }
                    fill =
                        Self.idleFill(
                            accent: accent.color, page: page, inks: inks,
                            target: traits.accessibilityContrast == .high ? 7 : 4.5
                        ).uiColor
                }
                passages.append((annotation, fill, selected))
                storage.addAttributes(
                    [
                        Self.annotationKey: annotation.threadIDs.map(String.init).joined(separator: ","),
                    ], range: annotation.range)
            }
            applySelectedInk(in: storage)
            revealPendingThread()
        }

        /// Comment fills are the only source ink that follows the personal accent.
        func accentDidChange() {
            if !verifiedAnnotations.isEmpty { editor.highlight() }
        }

        func selectionDidChange() {
            editor.textView.setNeedsLayout()
            guard !updatingSelection, !originalInk.isEmpty, annotatedGeneration == editor.generation,
                editor.isSettled, editor.textView.textStorage.length == editor.document.text.utf16.count
            else { return }
            updatingSelection = true
            defer { updatingSelection = false }
            let storage = editor.textView.textStorage
            let undo = editor.textView.undoManager
            undo?.disableUndoRegistration()
            storage.beginEditing()
            for original in originalInk {
                storage.addAttribute(.foregroundColor, value: original.color, range: original.range)
            }
            applySelectedInk(in: storage)
            storage.endEditing()
            undo?.enableUndoRegistration()
            editor.textView.setNeedsDisplay()
        }

        private func applySelectedInk(in storage: NSTextStorage) {
            for passage in passages where passage.selected {
                for range in unselectedRanges(passage.annotation.range) {
                    storage.addAttribute(.foregroundColor, value: onSelected, range: range)
                }
            }
        }

        // Platform gap: TextKit 2's highlight style offers only its own color schemes, with no
        // selected state or fill of our own, and backgroundColor draws square runs. Remove these
        // layers when a text highlight takes a fill color.
        func layoutBackgrounds() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard annotatedGeneration == editor.generation, editor.isSettled else { return }
            backgroundLayer.sublayers = nil
            guard let manager = editor.textView.textLayoutManager, !isSuspended else { return }
            let inset = editor.textView.textContainerInset
            var selectedFrames: [CGRect] = []
            var selectedFill: UIColor?
            for passage in passages {
                var frames: [CGRect] = []
                for range in unselectedRanges(passage.annotation.range) {
                    guard let native = nativeRange(range) else { continue }
                    manager.enumerateTextSegments(
                        in: native, type: .highlight, options: [.rangeNotRequired]
                    ) { _, frame, _, _ in
                        if frame.width > 0, frame.height > 0 {
                            frames.append(
                                frame.offsetBy(dx: inset.left, dy: inset.top).insetBy(dx: -1, dy: 0))
                        }
                        return true
                    }
                }
                if passage.selected {
                    selectedFrames.append(contentsOf: frames)
                    selectedFill = passage.fill
                } else {
                    addBackground(frames: frames, fill: passage.fill)
                }
            }
            if let selectedFill {
                addBackground(frames: Self.continuousLineRects(selectedFrames), fill: selectedFill)
            }
        }

        static func continuousLineRects(_ frames: [CGRect]) -> [CGRect] {
            var result: [CGRect] = []
            for frame in frames.sorted(by: {
                $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
            }) {
                if let previous = result.last,
                    abs(previous.minY - frame.minY) < 0.5,
                    abs(previous.maxY - frame.maxY) < 0.5,
                    frame.minX <= previous.maxX + 0.5, frame.maxX >= previous.minX
                {
                    result[result.count - 1] = previous.union(frame)
                } else {
                    result.append(frame)
                }
            }
            return result
        }

        private func addBackground(frames: [CGRect], fill: UIColor) {
            let path = UIBezierPath()
            for frame in frames {
                path.append(UIBezierPath(roundedRect: frame, cornerRadius: 3))
            }
            let layer = CAShapeLayer()
            layer.path = path.cgPath
            layer.fillColor = fill.cgColor
            backgroundLayer.addSublayer(layer)
        }

        func editMenu(ranges: [NSRange], suggestedActions: [UIMenuElement]) -> UIMenu? {
            let actions: [UIMenuElement] = [
                openAction(ids: threadIDs(intersecting: ranges)), addAction(ranges: ranges),
            ].compactMap { $0 }
            guard !actions.isEmpty else { return nil }
            return UIMenu(
                children: suggestedActions + [UIMenu(options: .displayInline, children: actions)])
        }

        private func addAction(ranges: [NSRange]) -> UIAction? {
            guard editor.comments != nil, !isSuspended,
                ranges.count == 1, let range = ranges.first, editor.isSettled,
                case let quote = (editor.document.text as NSString).substring(with: range),
                CommentQuote.isQuotable(quote)
            else { return nil }
            return UIAction(
                title: String(localized: "Add Comment", bundle: .module),
                image: UIImage(systemName: "text.bubble")
            ) { [weak self] _ in
                self?.addComment(quote)
            }
        }

        private func openAction(ids: [Int64]) -> UIAction? {
            guard !ids.isEmpty, editor.comments != nil else { return nil }
            return UIAction(
                title: String(localized: "View Comment", bundle: .module),
                image: UIImage(systemName: "text.bubble")
            ) { [weak self] _ in
                self?.openThreads(ids)
            }
        }

        private func threadIDs(intersecting ranges: [NSRange]) -> [Int64] {
            guard !isSuspended, editor.isSettled else { return [] }
            var seen: Set<Int64> = []
            return verifiedAnnotations.filter { annotation in
                ranges.contains { range in
                    range.length == 0
                        ? NSLocationInRange(range.location, annotation.range)
                        : NSIntersectionRange(range, annotation.range).length > 0
                }
            }.flatMap(\.threadIDs).filter { seen.insert($0).inserted }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
            -> Bool
        {
            guard !editor.textView.isFirstResponder, editor.comments != nil, !isSuspended, editor.isSettled
            else { return false }
            let ids = threadIDs(at: touch.location(in: editor.textView))
            pendingTap = ids.isEmpty ? nil : ids
            return !ids.isEmpty
        }

        func threadIDs(at point: CGPoint) -> [Int64] {
            guard let manager = editor.textView.textLayoutManager,
                let position = editor.textView.closestPosition(to: point)
            else { return [] }
            let offset = editor.textView.offset(from: editor.textView.beginningOfDocument, to: position)
            let inset = editor.textView.textContainerInset
            let textPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            var ids: [Int64] = []
            var seen: Set<Int64> = []
            for passage in passages
            where passage.annotation.start <= offset && passage.annotation.end >= offset {
                guard let range = nativeRange(passage.annotation.range) else { continue }
                var contains = false
                manager.enumerateTextSegments(
                    in: range, type: .standard, options: [.rangeNotRequired]
                ) { _, frame, _, _ in
                    contains = frame.insetBy(dx: -2, dy: -2).contains(textPoint)
                    return !contains
                }
                if contains {
                    ids += passage.annotation.threadIDs.filter { seen.insert($0).inserted }
                }
            }
            return ids
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            (other as? UITapGestureRecognizer).map { $0.numberOfTapsRequired > 1 } == true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === selectionTap || other === selectionTap
        }

        @objc private func openTappedPassage() {
            guard let pendingTap else { return }
            self.pendingTap = nil
            openThreads(pendingTap)
        }

        @objc private func selectTappedWord() {
            let view = editor.textView
            guard !view.isFirstResponder, editor.isSettled, !isSuspended,
                let position = view.closestPosition(to: selectionTap.location(in: view)),
                let caret = view.textRange(from: position, to: position)
            else { return }
            pendingTap = nil
            view.selectedTextRange = caret
            view.becomeFirstResponder()
            view.select(nil)
        }

        func revealPendingThread() {
            guard pendingReveal != nil, !isSuspended, editor.textView.window != nil,
                !editor.textView.isHidden, scrollTask == nil,
                editor.textView.bounds.width > 0, editor.textView.bounds.height > 0
            else { return }
            scrollTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                defer { if !Task.isCancelled { self.scrollTask = nil } }
                guard let threadID = self.pendingReveal, !self.isSuspended, self.editor.isSettled,
                    let annotation = self.verifiedAnnotations.first(where: {
                        $0.threadIDs.contains(threadID)
                    }),
                    self.editor.textView.window != nil, !self.editor.textView.isHidden
                else { return }
                self.pendingReveal = nil
                self.editor.textView.revealPassage(annotation.range)
            }
        }

        func suspendForFind() {
            suspendsForFind = true
            editor.highlight()
        }

        func frontMatterVisibilityDidChange() {
            if !quotes.isEmpty { editor.highlight() }
        }

        // Platform gap: UITextView is its own find interaction's delegate and tells ours nothing when
        // Find opens or closes, so layout checks the navigator. Remove when UITextViewDelegate does.
        func findVisibilityDidChange() {
            let visible = editor.textView.findInteraction?.isFindNavigatorVisible == true
            guard suspendsForFind != visible, pendingFindUpdate == nil
            else { return }
            pendingFindUpdate = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                self.pendingFindUpdate = nil
                let visible = self.editor.textView.findInteraction?.isFindNavigatorVisible == true
                guard self.suspendsForFind != visible else { return }
                self.suspendsForFind = visible
                self.editor.highlight()
            }
        }

        func suspendForWritingTools() {
            suspendsForWritingTools = true
            editor.highlight()
        }

        func resumeAfterWritingTools() {
            suspendsForWritingTools = false
        }

        private func nativeRange(_ range: NSRange) -> NSTextRange? {
            guard let content = editor.textView.textLayoutManager?.textContentManager,
                let start = content.location(content.documentRange.location, offsetBy: range.location),
                let end = content.location(start, offsetBy: range.length)
            else { return nil }
            return NSTextRange(location: start, end: end)
        }

        private func unselectedRanges(_ range: NSRange) -> [NSRange] {
            let selection = editor.textView.selectedRange
            guard editor.textView.isFirstResponder, selection.length > 0 else { return [range] }
            let overlap = NSIntersectionRange(range, selection)
            guard overlap.length > 0 else { return [range] }
            var ranges: [NSRange] = []
            if overlap.location > range.location {
                ranges.append(NSRange(location: range.location, length: overlap.location - range.location))
            }
            if NSMaxRange(overlap) < NSMaxRange(range) {
                ranges.append(
                    NSRange(location: NSMaxRange(overlap), length: NSMaxRange(range) - NSMaxRange(overlap)))
            }
            return ranges
        }

        static func idleFill(
            accent: RGBColor, page: RGBColor, inks: [(RGBColor, Double)], target: Double
        ) -> RGBColor {
            let minimums = inks.map {
                min(target, page.mixed(toward: $0.0, amount: $0.1).contrast(with: page))
            }
            for step in 0...128 {
                let candidate = page.mixed(toward: accent, amount: 0.5 - Double(step) / 256)
                if zip(inks, minimums).allSatisfy({ ink, minimum in
                    candidate.mixed(toward: ink.0, amount: ink.1).contrast(with: candidate) + 0.000_001
                        >= minimum
                }) {
                    return candidate
                }
            }

            preconditionFailure("The native page must preserve its original source-ink contrast.")
        }

        private func updateAccessibility() {
            let view = editor.textView
            guard !isSuspended,
                let selectedID = editor.comments?.selectedThreadID,
                verifiedAnnotations.contains(where: { $0.threadIDs.contains(selectedID) }),
                let quote = quotes.first(where: { $0.threadID == selectedID })?.quote
            else {
                view.accessibilityCustomContent = []
                return
            }
            let excerpt = String(quote.prefix(160)) + (quote.count > 160 ? "…" : "")
            let content = AXCustomContent(
                label: String(localized: "Selected Comment", bundle: .module), value: excerpt)
            content.importance = .high
            view.accessibilityCustomContent = [content]
        }

        /// Hands the editor the threads it matched once the update that matched them ends.
        private func publish(_ ids: Set<Int64>?) {
            guard matchedIDs != ids else { return }
            matchedIDs = ids
            publication?.cancel()
            publication = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.publication = nil
                self.editor.matchedThreadIDs = ids
            }
        }
    }

    extension MarkdownEditor {
        /// Scrolls a thread's quoted passage into view, once the editor shows it.
        public func revealThread(_ id: Int64) {
            commentAnnotator.reveal(id)
        }
    }
#endif
