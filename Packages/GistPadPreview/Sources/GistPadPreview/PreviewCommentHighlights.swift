import Foundation
import GistPadComments

struct PreviewCommentCatalog: Decodable {
    let version: Int
    let documentID: String
    let generation: String
    let segments: [String]

    static func decode(_ value: Any, document: PreviewDocument) throws -> Self {
        let catalog: Self = try PreviewBridge.decode(
            value, maximumBytes: PreviewDocument.maximumLength * 32)
        guard catalog.version == 1, catalog.documentID == document.id,
              catalog.generation == String(document.generation) else {
            throw PreviewFailure.staleDocument
        }
        guard catalog.segments.count <= PreviewDocument.maximumLength else {
            throw PreviewFailure.invalidMessage
        }
        var length = 0
        for segment in catalog.segments {
            length += segment.utf16.count
            guard length <= PreviewDocument.maximumLength * 4 else {
                throw PreviewFailure.invalidMessage
            }
        }
        return catalog
    }
}

struct PreviewCommentSelection: Decodable {
    let version: Int
    let documentID: String
    let generation: String
    let quote: String?

    static func decode(_ value: Any, document: PreviewDocument) throws -> Self {
        guard let envelope = value as? [String: Any], envelope.keys.contains("quote") else {
            throw PreviewFailure.invalidMessage
        }
        let selection: Self = try PreviewBridge.decode(
            value, maximumBytes: PreviewDocument.maximumLength * 32)
        guard selection.version == 1, selection.documentID == document.id,
              selection.generation == String(document.generation) else {
            throw PreviewFailure.staleDocument
        }
        guard (selection.quote?.utf16.count ?? 0) <= PreviewDocument.maximumLength * 4 else {
            throw PreviewFailure.invalidMessage
        }
        return selection
    }
}

enum PreviewCommentActivation {
    private struct Envelope: Decodable {
        let version: Int
        let type: String
        let documentID: String
        let generation: String
        let segment: Int
        let start: Int
        let end: Int
    }

    static func decode(
        _ value: Any, document: PreviewDocument,
        highlights: [CommentQuoteHighlight], configuration: CommentHighlightConfiguration
    ) throws -> [Int64] {
        let message: Envelope = try PreviewBridge.decode(value, maximumBytes: 16_384)
        guard message.version == 1, message.type == "commentActivate" else {
            throw PreviewFailure.invalidMessage
        }
        guard message.documentID == document.id, message.generation == String(document.generation)
        else { throw PreviewFailure.staleDocument }
        guard let highlight = highlights.first(where: {
            $0.segment == message.segment && $0.start == message.start && $0.end == message.end
        }),
              configuration.showsInlineComments ||
                configuration.selectedCommentID.map(highlight.commentIDs.contains) == true else {
            throw PreviewFailure.invalidMessage
        }
        return highlight.commentIDs
    }
}

#if os(iOS)
import UIKit
import WebKit

@MainActor
final class PreviewCommentHighlights {
    weak var webView: WKWebView?
    private let onFailure: @MainActor (PreviewFailure) -> Void
    private var onOpen: (@MainActor ([Int64]) -> Void)?
    private var onLinkedIDs: (@MainActor (Set<Int64>) -> Void)?
    private var onAdd: (@MainActor (String) -> Void)?
    private var document: PreviewDocument?
    private var renderedDocument: PreviewDocument?
    private var configuration = CommentHighlightConfiguration()
    private var accent = "#0EA5E9"
    private var catalog: PreviewCommentCatalog?
    private var matchedQuotes: [CommentQuote]?
    private var highlights: [CommentQuoteHighlight] = []
    private var linkedIDs: Set<Int64>?
    private var task: Task<Void, Never>?
    private var ticket = UUID()
    private var needsSelectedScroll = false

    init(onFailure: @escaping @MainActor (PreviewFailure) -> Void) {
        self.onFailure = onFailure
    }

    func update(
        document: PreviewDocument, configuration: CommentHighlightConfiguration, accent: String,
        onOpen: (@MainActor ([Int64]) -> Void)?,
        onLinkedIDs: (@MainActor (Set<Int64>) -> Void)?,
        onAdd: (@MainActor (String) -> Void)?
    ) {
        let needsInitialReport = self.onLinkedIDs == nil && onLinkedIDs != nil
        let changesInteraction = (self.onOpen == nil) != (onOpen == nil)
        let changesReveal = self.document != document ||
            self.configuration.selectedCommentID != configuration.selectedCommentID ||
            self.configuration.revealRevision != configuration.revealRevision
        self.onOpen = onOpen
        self.onLinkedIDs = onLinkedIDs
        self.onAdd = onAdd
        let changed = changesInteraction || self.document != document || self.configuration != configuration ||
            self.accent != accent
        if self.document != document {
            reset()
            self.document = document
        }
        self.configuration = configuration
        if changesReveal { needsSelectedScroll = configuration.selectedCommentID != nil }
        self.accent = accent
        if needsInitialReport, let linkedIDs { publish(linkedIDs, force: true) }
        if changed, renderedDocument == document { refresh() }
    }

    func rendered(_ document: PreviewDocument) {
        guard self.document == document else { return }
        renderedDocument = document
        refresh()
    }

    func activate(_ body: Any) throws {
        guard let document, renderedDocument == document,
              matchedQuotes == configuration.quotes else { throw PreviewFailure.staleDocument }
        let ids = try PreviewCommentActivation.decode(
            body, document: document, highlights: highlights, configuration: configuration)
        onOpen?(ids)
    }

    func addCommentMenu() -> UIDeferredMenuElement? {
        guard onAdd != nil, let document, renderedDocument == document else { return nil }
        return .uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, let webView = self.webView else {
                    completion([])
                    return
                }
                do {
                    guard let value = try await webView.callAsyncJavaScript(
                        "return window.gistpadPreview.commentSelection();",
                        arguments: [:], in: nil, contentWorld: .page) else {
                        throw PreviewFailure.invalidMessage
                    }
                    guard self.document == document, self.renderedDocument == document,
                          self.onAdd != nil else {
                        completion([])
                        return
                    }
                    let selection = try PreviewCommentSelection.decode(value, document: document)
                    guard let quote = selection.quote, CommentQuoteMatcher.isEligibleSelection(quote) else {
                        completion([])
                        return
                    }
                    let action = UIAction(
                        title: String(localized: "Add Comment", bundle: .module),
                        image: UIImage(systemName: "text.bubble")
                    ) { [weak self] _ in
                        guard let self else { return }
                        guard self.document == document, self.renderedDocument == document else {
                            self.onFailure(.staleDocument)
                            return
                        }
                        self.onAdd?(quote)
                    }
                    completion([action])
                } catch {
                    completion([])
                    guard self.document == document else { return }
                    self.onFailure(.renderer("The selected quote could not be read: \(error.localizedDescription)"))
                }
            }
        }
    }

    func reset() {
        ticket = UUID()
        task?.cancel()
        task = nil
        renderedDocument = nil
        catalog = nil
        matchedQuotes = nil
        highlights = []
        linkedIDs = nil
        needsSelectedScroll = configuration.selectedCommentID != nil
    }

    private func refresh() {
        task?.cancel()
        ticket = UUID()
        let ticket = ticket
        guard let document, renderedDocument == document, let webView else { return }
        let configuration = configuration
        let accent = accent
        let allowsInteraction = onOpen != nil
        let reveal = needsSelectedScroll
        if configuration.quotes.isEmpty, highlights.isEmpty {
            matchedQuotes = []
            publish([])
            return
        }
        task = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                if !configuration.quotes.isEmpty, self.catalog == nil {
                    guard let value = try await webView.callAsyncJavaScript(
                        "return window.gistpadPreview.commentSegments();",
                        arguments: [:], in: nil, contentWorld: .page) else {
                        throw PreviewFailure.invalidMessage
                    }
                    guard !Task.isCancelled, self.ticket == ticket else { return }
                    self.catalog = try PreviewCommentCatalog.decode(value, document: document)
                }
                if configuration.quotes.isEmpty {
                    self.highlights = []
                    self.matchedQuotes = []
                } else if self.matchedQuotes != configuration.quotes {
                    guard let segments = self.catalog?.segments else {
                        throw PreviewFailure.invalidMessage
                    }
                    let highlights = await Task.detached(priority: .userInitiated) {
                        CommentQuoteMatcher.highlights(quotes: configuration.quotes, segments: segments)
                    }.value
                    guard !Task.isCancelled, self.ticket == ticket else { return }
                    self.highlights = highlights
                    self.matchedQuotes = configuration.quotes
                }
                guard !Task.isCancelled, self.ticket == ticket else { return }
                let ranges: [[String: Any]] = self.highlights.map { highlight in
                    [
                        "segment": highlight.segment, "start": highlight.start, "end": highlight.end,
                        "commentIDs": highlight.commentIDs.map(String.init)
                    ]
                }
                let selected: Any
                if let id = configuration.selectedCommentID {
                    selected = String(id)
                } else {
                    selected = NSNull()
                }
                let payload: [String: Any] = [
                    "version": 1, "documentID": document.id, "generation": String(document.generation),
                    "highlights": ranges, "selectedCommentID": selected,
                    "revealRevision": String(configuration.revealRevision),
                    "showsInlineComments": configuration.showsInlineComments,
                    "allowsInteraction": allowsInteraction, "accent": accent
                ]
                let target = try await webView.callAsyncJavaScript(
                    """
                    window.gistpadPreview.setCommentHighlights(payload);
                    if (!reveal) return null;
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    const target = document.querySelector('.comment-selected[data-comment-ids]');
                    if (!target) return null;
                    const rect = target.getBoundingClientRect();
                    return { top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY };
                    """,
                    arguments: ["payload": payload, "reveal": reveal], in: nil, contentWorld: .page)
                guard !Task.isCancelled, self.ticket == ticket else { return }
                if reveal {
                    if let target, !(target is NSNull) {
                        guard let rect = target as? [String: Double],
                              let top = rect["top"], let bottom = rect["bottom"],
                              top.isFinite, bottom.isFinite, bottom >= top else {
                            throw PreviewFailure.invalidMessage
                        }
                        self.reveal(top: CGFloat(top), bottom: CGFloat(bottom), in: webView)
                    }
                    self.needsSelectedScroll = false
                }
                self.publish(Set(self.highlights.flatMap(\.commentIDs)))
            } catch {
                guard !Task.isCancelled, self.ticket == ticket else { return }
                self.matchedQuotes = nil
                self.highlights = []
                self.publish([])
                self.onFailure(.renderer("Comment highlights could not be updated: \(error.localizedDescription)"))
            }
        }
    }

    private func reveal(top: CGFloat, bottom: CGFloat, in webView: WKWebView) {
        webView.layoutIfNeeded()
        let scroll = webView.scrollView
        let insets = scroll.adjustedContentInset
        let height = scroll.bounds.height - insets.top - insets.bottom
        let y = bottom - top > height
            ? top - insets.top
            : (top + bottom) / 2 - insets.top - height / 2
        let minimum = -insets.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        scroll.setContentOffset(
            CGPoint(x: scroll.contentOffset.x, y: min(maximum, max(minimum, y))),
            animated: false)
    }

    private func publish(_ ids: Set<Int64>, force: Bool = false) {
        guard force || linkedIDs != ids else { return }
        linkedIDs = ids
        let document = document
        Task { @MainActor [weak self] in
            guard let self, self.document == document, self.linkedIDs == ids else { return }
            self.onLinkedIDs?(ids)
        }
    }
}
#endif
