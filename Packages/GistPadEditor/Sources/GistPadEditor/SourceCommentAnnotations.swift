#if canImport(UIKit)
  import Accessibility
  import GistPadAppearance
  import GistPadComments
  import UIKit

  @MainActor
  final class SourceCommentAnnotations: NSObject, UIGestureRecognizerDelegate {
    static let annotationKey = NSAttributedString.Key("dev.gistpad.comment.highlight")
    private struct Passage {
      let highlight: CommentQuoteHighlight
      let fill: UIColor
      let selected: Bool
    }
    private unowned let session: DocumentSession
    private let backgroundLayer = CALayer()
    private var configuration = CommentHighlightConfiguration()
    private var onOpen: (@MainActor ([Int64]) -> Void)?
    private var onLinkedIDs: (@MainActor (Set<Int64>) -> Void)?
    private var onAdd: (@MainActor (String) -> Void)?
    private var linkedIDs: Set<Int64>?
    private var passages: [Passage] = []
    private var verifiedHighlights: [CommentQuoteHighlight] = []
    private var matchedGeneration: UInt64?
    private var matchedQuotes: [CommentQuote] = []
    private var sourceHighlights: [CommentQuoteHighlight] = []
    private var originalInk: [(range: NSRange, color: Any)] = []
    private var paintedGeneration: UInt64?
    private var suspendsForFind = false
    private var suspendsForWritingTools = false
    private var updatingSelection = false
    private var pendingTap: (ids: [Int64], generation: UInt64)?
    private var pendingFindUpdate: Task<Void, Never>?
    private var publication: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?
    private var needsSelectedScroll = false
    private var onSelected = UIColor.label
    private lazy var tap = UITapGestureRecognizer(
      target: self, action: #selector(openTappedPassage))
    private lazy var selectionTap = UITapGestureRecognizer(
      target: self, action: #selector(selectTappedWord))

    init(session: DocumentSession) {
      self.session = session
      super.init()
      session.textView.layer.insertSublayer(backgroundLayer, at: 0)
      tap.delegate = self
      selectionTap.numberOfTapsRequired = 2
      selectionTap.cancelsTouchesInView = false
      selectionTap.delaysTouchesBegan = false
      selectionTap.delaysTouchesEnded = false
      selectionTap.delegate = self
      tap.require(toFail: selectionTap)
      session.textView.addGestureRecognizer(selectionTap)
      session.textView.addGestureRecognizer(tap)
    }

    func configure(
      _ configuration: CommentHighlightConfiguration,
      onOpen: (@MainActor ([Int64]) -> Void)?,
      onLinkedIDs: (@MainActor (Set<Int64>) -> Void)?,
      onAdd: (@MainActor (String) -> Void)?
    ) {
      let needsInitialReport = self.onLinkedIDs == nil && onLinkedIDs != nil
      let changesInteraction = (self.onOpen == nil) != (onOpen == nil)
      if self.configuration.selectedCommentID != configuration.selectedCommentID
        || self.configuration.revealRevision != configuration.revealRevision
      {
        needsSelectedScroll = configuration.selectedCommentID != nil
        scrollTask?.cancel()
        scrollTask = nil
      }
      self.onOpen = onOpen
      self.onLinkedIDs = onLinkedIDs
      self.onAdd = onAdd
      if self.configuration != configuration || changesInteraction {
        self.configuration = configuration
        session.highlight()
      }
      if needsInitialReport { publish(linkedIDs ?? [], force: true) }
      scrollSelectedCommentIfNeeded()
    }

    func paint(in storage: NSTextStorage) {
      passages = []
      backgroundLayer.sublayers = nil
      session.textView.setNeedsLayout()
      originalInk = []
      paintedGeneration = session.generation
      if matchedGeneration != session.generation || matchedQuotes != configuration.quotes {
        sourceHighlights =
          configuration.quotes.isEmpty
          ? []
          : CommentQuoteMatcher.highlights(
            quotes: configuration.quotes, segments: [session.text])
        matchedGeneration = session.generation
        matchedQuotes = configuration.quotes
      }
      let highlights = sourceHighlights.filter { $0.start >= session.contentStart }
      verifiedHighlights = highlights
      publish(Set(highlights.flatMap(\.commentIDs)))
      updateAccessibility()
      guard !highlights.isEmpty, !suspendsForFind, !suspendsForWritingTools else {
        return
      }
      let traits = session.textView.traitCollection
      let accent = traits[PersonalAccentTrait.self]
      let roles = accent.roles(traits: traits)
      onSelected = roles.onFill.uiColor
      guard
        let page = RGBColor(
          uiColor: UIColor.systemBackground.resolvedColor(with: traits))
      else {
        preconditionFailure("Comment highlights require an opaque native page.")
      }
      for highlight in highlights {
        let selected = configuration.selectedCommentID.map(highlight.commentIDs.contains) ?? false
        guard configuration.showsInlineComments || selected else { continue }
        let fill: UIColor
        if selected {
          fill = roles.fill.uiColor
          storage.enumerateAttribute(.foregroundColor, in: highlight.range) { color, range, _ in
            originalInk.append((range, color ?? UIColor.label))
          }
        } else {
          var inks: [(RGBColor, Double)] = []
          storage.enumerateAttribute(.foregroundColor, in: highlight.range) { value, _, _ in
            let color = (value as? UIColor ?? .label).resolvedColor(with: traits)
            guard let ink = RGBColor(uiColor: color.withAlphaComponent(1)) else {
              preconditionFailure("Source annotation ink must resolve to sRGB.")
            }
            inks.append((ink, Double(color.cgColor.alpha)))
          }
          fill =
            Self.idleFill(
              accent: accent.color, page: page, inks: inks,
              target: traits.accessibilityContrast == .high ? 7 : 4.5
            ).uiColor
        }
        passages.append(Passage(highlight: highlight, fill: fill, selected: selected))
        storage.addAttributes(
          [
            Self.annotationKey: highlight.commentIDs.map(String.init).joined(separator: ","),
          ], range: highlight.range)
      }
      applySelectedInk(in: storage)
      scrollSelectedCommentIfNeeded()
    }

    func selectionDidChange() {
      session.textView.setNeedsLayout()
      guard !updatingSelection, !originalInk.isEmpty, paintedGeneration == session.generation,
        !session.isComposing, !session.writingToolsActive,
        session.textView.markedTextRange == nil,
        session.textView.textStorage.length == session.text.utf16.count
      else { return }
      updatingSelection = true
      defer { updatingSelection = false }
      let storage = session.textView.textStorage
      let undo = session.textView.undoManager
      let undoEnabled = undo?.isUndoRegistrationEnabled == true
      if undoEnabled { undo?.disableUndoRegistration() }
      storage.beginEditing()
      for original in originalInk {
        storage.addAttribute(.foregroundColor, value: original.color, range: original.range)
      }
      applySelectedInk(in: storage)
      storage.endEditing()
      if undoEnabled { undo?.enableUndoRegistration() }
      session.textView.setNeedsDisplay()
    }

    private func applySelectedInk(in storage: NSTextStorage) {
      for passage in passages where passage.selected {
        for range in unselectedRanges(passage.highlight.range) {
          storage.addAttribute(.foregroundColor, value: onSelected, range: range)
        }
      }
    }

    func layoutBackgrounds() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      backgroundLayer.sublayers = nil
      guard let manager = session.textView.textLayoutManager,
        paintedGeneration == session.generation, !suspendsForFind, !suspendsForWritingTools,
        !session.isComposing,
        session.textView.markedTextRange == nil, !session.writingToolsActive
      else { return }
      let inset = session.textView.textContainerInset
      var selectedFrames: [CGRect] = []
      var selectedFill: UIColor?
      for passage in passages {
        var frames: [CGRect] = []
        for range in unselectedRanges(passage.highlight.range) {
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
      let ids = threadIDs(intersecting: ranges)
      var actions: [UIMenuElement] = []
      if let action = openAction(ids: ids) { actions.append(action) }
      if let action = addAction(ranges: ranges) { actions.append(action) }
      guard !actions.isEmpty else { return nil }
      return UIMenu(
        children: suggestedActions + [UIMenu(options: .displayInline, children: actions)])
    }

    private func addAction(ranges: [NSRange]) -> UIAction? {
      guard onAdd != nil, !suspendsForFind, !suspendsForWritingTools,
        ranges.count == 1, let range = ranges.first,
        !session.isComposing, !session.writingToolsActive, session.textView.markedTextRange == nil,
        range.location >= session.contentStart, range.length >= 0,
        range.location <= session.text.utf16.count,
        range.length <= session.text.utf16.count - range.location,
        let native = Range(range, in: session.text)
      else { return nil }
      let quote = String(session.text[native])
      guard CommentQuoteMatcher.isEligibleSelection(quote) else { return nil }
      let generation = session.generation
      return UIAction(
        title: String(localized: "Add Comment", bundle: .module),
        image: UIImage(systemName: "text.bubble")
      ) { [weak self] _ in
        guard let self else { return }
        guard self.session.generation == generation, !self.session.isComposing,
          !self.session.writingToolsActive
        else {
          self.session.inputError = String(
            localized: "The note changed. Select the text again before commenting.", bundle: .module
          )
          return
        }
        self.onAdd?(quote)
      }
    }

    private func openAction(ids: [Int64]) -> UIAction? {
      guard !ids.isEmpty, onOpen != nil else { return nil }
      let generation = session.generation
      return UIAction(
        title: String(localized: "View Comment", bundle: .module),
        image: UIImage(systemName: "text.bubble")
      ) { [weak self] _ in
        guard let self else { return }
        let currentIDs = Set(self.threadIDs(intersecting: self.verifiedHighlights.map(\.range)))
        guard self.session.generation == generation, ids.allSatisfy(currentIDs.contains) else {
          self.reportChangedQuote()
          return
        }
        self.onOpen?(ids)
      }
    }

    private func threadIDs(intersecting ranges: [NSRange]) -> [Int64] {
      guard paintedGeneration == session.generation, !suspendsForFind, !suspendsForWritingTools,
        !session.isComposing,
        !session.writingToolsActive
      else { return [] }
      var seen: Set<Int64> = []
      return verifiedHighlights.filter { highlight in
        ranges.contains { range in
          range.length == 0
            ? NSLocationInRange(range.location, highlight.range)
            : NSIntersectionRange(range, highlight.range).length > 0
        }
      }.flatMap(\.commentIDs).filter { seen.insert($0).inserted }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
      -> Bool
    {
      guard !session.textView.isFirstResponder, onOpen != nil,
        !suspendsForFind, !suspendsForWritingTools,
        paintedGeneration == session.generation,
        !session.writingToolsActive, !session.isComposing
      else { return false }
      let point = touch.location(in: session.textView)
      let ids = threadIDs(at: point)
      pendingTap = ids.isEmpty ? nil : (ids, session.generation)
      return !ids.isEmpty
    }

    func threadIDs(at point: CGPoint) -> [Int64] {
      guard let manager = session.textView.textLayoutManager,
        let position = session.textView.closestPosition(to: point)
      else { return [] }
      let offset = session.textView.offset(from: session.textView.beginningOfDocument, to: position)
      let inset = session.textView.textContainerInset
      let textPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
      var ids: [Int64] = []
      var seen: Set<Int64> = []
      for passage in passages
      where passage.highlight.start <= offset && passage.highlight.end >= offset {
        guard let range = nativeRange(passage.highlight.range) else { continue }
        var contains = false
        manager.enumerateTextSegments(
          in: range, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
          contains = frame.insetBy(dx: -2, dy: -2).contains(textPoint)
          return !contains
        }
        if contains {
          ids += passage.highlight.commentIDs.filter { seen.insert($0).inserted }
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
      let currentIDs = Set(passages.flatMap(\.highlight.commentIDs))
      guard pendingTap.generation == session.generation,
        pendingTap.ids.allSatisfy(currentIDs.contains)
      else {
        reportChangedQuote()
        return
      }
      onOpen?(pendingTap.ids)
    }

    @objc private func selectTappedWord() {
      let view = session.textView
      guard !view.isFirstResponder, !session.isComposing, !session.writingToolsActive,
        !suspendsForFind, !suspendsForWritingTools,
        let position = view.closestPosition(to: selectionTap.location(in: view)),
        let caret = view.textRange(from: position, to: position)
      else { return }
      pendingTap = nil
      view.selectedTextRange = caret
      view.becomeFirstResponder()
      view.select(nil)
    }

    private func reportChangedQuote() {
      session.inputError = String(
        localized: "This comment is no longer linked here. Select the quote again.", bundle: .module
      )
    }

    func scrollSelectedCommentIfNeeded() {
      guard needsSelectedScroll, !suspendsForFind, !suspendsForWritingTools,
        session.textView.window != nil,
        !session.textView.isHidden, scrollTask == nil,
        session.textView.bounds.width > 0, session.textView.bounds.height > 0
      else { return }
      scrollTask = Task { @MainActor [weak self] in
        await Task.yield()
        guard !Task.isCancelled, let self else { return }
        defer { if !Task.isCancelled { self.scrollTask = nil } }
        guard self.needsSelectedScroll,
          !self.suspendsForFind, !self.suspendsForWritingTools,
          !self.session.isComposing, !self.session.writingToolsActive,
          self.paintedGeneration == self.session.generation,
          let selectedID = self.configuration.selectedCommentID,
          let highlight = self.verifiedHighlights.first(where: {
            $0.commentIDs.contains(selectedID)
          }),
          self.session.textView.window != nil, !self.session.textView.isHidden
        else { return }
        guard !Task.isCancelled, self.paintedGeneration == self.session.generation,
          self.configuration.selectedCommentID == selectedID
        else { return }
        self.needsSelectedScroll = false
        guard (self.session.textView as? AnchoredTextView)?.revealPassage(highlight.range) == true else {
          self.session.inputError = String(
            localized: "The comment passage could not be revealed.", bundle: .module)
          return
        }
      }
    }

    func suspendForFind() {
      suspendsForFind = true
      session.highlight()
    }

    func frontMatterVisibilityDidChange() {
      if !configuration.quotes.isEmpty { session.highlight() }
    }

    func findVisibilityDidChange() {
      let visible = session.textView.findInteraction?.isFindNavigatorVisible == true
      guard suspendsForFind != visible, pendingFindUpdate == nil
      else { return }
      pendingFindUpdate = Task { @MainActor [weak self] in
        await Task.yield()
        guard let self else { return }
        self.pendingFindUpdate = nil
        let visible = self.session.textView.findInteraction?.isFindNavigatorVisible == true
        guard self.suspendsForFind != visible else { return }
        self.suspendsForFind = visible
        self.session.highlight()
      }
    }

    func suspendForWritingTools() {
      suspendsForWritingTools = true
      session.highlight()
    }

    func resumeAfterWritingTools() {
      suspendsForWritingTools = false
    }

    private func nativeRange(_ range: NSRange) -> NSTextRange? {
      guard let content = session.textView.textLayoutManager?.textContentManager,
        let start = content.location(content.documentRange.location, offsetBy: range.location),
        let end = content.location(start, offsetBy: range.length)
      else { return nil }
      return NSTextRange(location: start, end: end)
    }

    private func unselectedRanges(_ range: NSRange) -> [NSRange] {
      let selection = session.textView.selectedRange
      guard session.textView.isFirstResponder, selection.length > 0 else { return [range] }
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
      guard let view = session.textView as? AnchoredTextView else {
        preconditionFailure("Comment annotations require the retained source text view.")
      }
      guard !suspendsForFind, !suspendsForWritingTools,
        let selectedID = configuration.selectedCommentID,
        verifiedHighlights.contains(where: { $0.commentIDs.contains(selectedID) }),
        let quote = configuration.quotes.first(where: { $0.commentID == selectedID })?.quote
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

    private func publish(_ ids: Set<Int64>, force: Bool = false) {
      guard force || linkedIDs != ids else { return }
      linkedIDs = ids
      let generation = session.generation
      publication?.cancel()
      publication = Task { @MainActor [weak self] in
        guard !Task.isCancelled, let self, self.session.generation == generation,
          self.linkedIDs == ids
        else { return }
        self.publication = nil
        self.onLinkedIDs?(ids)
      }
    }
  }
#endif
