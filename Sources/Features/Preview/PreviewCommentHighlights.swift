import Foundation
import Comments

struct PreviewCommentCatalog: Decodable {
    let segments: [String]
}

struct PreviewCommentSelection: Decodable {
    let quote: String?
}

enum PreviewCommentActivation {
    private struct Envelope: Decodable {
        let documentID: String
        let generation: UInt64
        let segment: Int
        let start: Int
        let end: Int
    }

    static func decode(
        _ value: Any, file: PreviewFile, highlights: [CommentQuoteHighlight]
    ) throws -> [Int64] {
        let message: Envelope = try PreviewBridge.decode(value)
        guard message.documentID == file.id, message.generation == file.generation,
              let highlight = highlights.first(where: {
                  $0.segment == message.segment && $0.start == message.start && $0.end == message.end
              }) else { throw PreviewBridge.invalidMessage }
        return highlight.commentIDs
    }
}

#if os(iOS)
import OSLog
import UIKit
import WebKit

@MainActor
final class PreviewCommentHighlights {
    weak var webView: WKWebView?
    private var onOpen: (@MainActor ([Int64]) -> Void)?
    private var onLinkedIDs: (@MainActor (Set<Int64>) -> Void)?
    private var onAdd: (@MainActor (String) -> Void)?
    private var file: PreviewFile?
    private var renderedFile: PreviewFile?
    private var configuration = CommentHighlightConfiguration()
    private var accent = "#0EA5E9"
    private var segments: [String]?
    private var matchedQuotes: [CommentQuote]?
    private var highlights: [CommentQuoteHighlight] = []
    private var linkedIDs: Set<Int64>?
    private var task: Task<Void, Never>?

    func update(
        file: PreviewFile, configuration: CommentHighlightConfiguration, accent: String,
        onOpen: (@MainActor ([Int64]) -> Void)?,
        onLinkedIDs: (@MainActor (Set<Int64>) -> Void)?,
        onAdd: (@MainActor (String) -> Void)?
    ) {
        let needsInitialReport = self.onLinkedIDs == nil && onLinkedIDs != nil
        let changesInteraction = (self.onOpen == nil) != (onOpen == nil)
        self.onOpen = onOpen
        self.onLinkedIDs = onLinkedIDs
        self.onAdd = onAdd
        let changed = changesInteraction || self.file != file || self.configuration != configuration ||
            self.accent != accent
        if self.file != file {
            reset()
            self.file = file
        }
        self.configuration = configuration
        self.accent = accent
        if needsInitialReport, let linkedIDs { publish(linkedIDs, force: true) }
        if changed, renderedFile == file { refresh() }
    }

    func rendered(_ file: PreviewFile) {
        guard self.file == file else { return }
        renderedFile = file
        refresh()
    }

    func activate(_ body: Any) throws {
        guard let file, renderedFile == file else { return }
        onOpen?(try PreviewCommentActivation.decode(body, file: file, highlights: highlights))
    }

    func addCommentMenu() -> UIDeferredMenuElement? {
        guard onAdd != nil, let file, renderedFile == file else { return nil }
        return .uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, let webView = self.webView else { return completion([]) }
                do {
                    let value = try await webView.callAsyncJavaScript(
                        "return window.gistpadPreview.commentSelection();",
                        arguments: [:], in: nil, contentWorld: .page)
                    let selection: PreviewCommentSelection = try PreviewBridge.decode(value)
                    guard self.renderedFile == file, let quote = selection.quote,
                          CommentQuoteMatcher.isEligibleSelection(quote) else { return completion([]) }
                    let action = UIAction(
                        title: String(localized: "Add Comment", bundle: .module),
                        image: UIImage(systemName: "text.bubble")
                    ) { [weak self] _ in
                        guard let self, self.renderedFile == file else { return }
                        self.onAdd?(quote)
                    }
                    completion([action])
                } catch {
                    Logger.preview.error("The selected quote couldn't be read: \(error.localizedDescription)")
                    completion([])
                }
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        renderedFile = nil
        segments = nil
        matchedQuotes = nil
        highlights = []
        linkedIDs = nil
    }

    private func refresh() {
        task?.cancel()
        guard let file, renderedFile == file, let webView else { return }
        let configuration = configuration
        let accent = accent
        let allowsInteraction = onOpen != nil
        if configuration.quotes.isEmpty, highlights.isEmpty {
            matchedQuotes = []
            publish([])
            return
        }
        task = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                if !configuration.quotes.isEmpty, self.segments == nil {
                    let value = try await webView.callAsyncJavaScript(
                        "return window.gistpadPreview.commentSegments();",
                        arguments: [:], in: nil, contentWorld: .page)
                    let catalog: PreviewCommentCatalog = try PreviewBridge.decode(value)
                    guard !Task.isCancelled else { return }
                    self.segments = catalog.segments
                }
                if configuration.quotes.isEmpty {
                    self.highlights = []
                    self.matchedQuotes = []
                } else if self.matchedQuotes != configuration.quotes, let segments = self.segments {
                    let highlights = await Task.detached(priority: .userInitiated) {
                        CommentQuoteMatcher.highlights(quotes: configuration.quotes, segments: segments)
                    }.value
                    guard !Task.isCancelled else { return }
                    self.highlights = highlights
                    self.matchedQuotes = configuration.quotes
                }
                let payload: [String: Any] = [
                    "highlights": self.highlights.map {
                        ["segment": $0.segment, "start": $0.start, "end": $0.end, "commentIDs": $0.commentIDs]
                    },
                    "selectedCommentID": configuration.selectedCommentID.map { $0 as Any } ?? NSNull(),
                    "revealRevision": configuration.revealRevision,
                    "showsInlineComments": configuration.showsInlineComments,
                    "allowsInteraction": allowsInteraction, "accent": accent
                ]
                // The page reveals the selected passage itself, within the native viewport's scroll padding.
                _ = try await webView.callAsyncJavaScript(
                    "window.gistpadPreview.setCommentHighlights(payload);",
                    arguments: ["payload": payload], in: nil, contentWorld: .page)
                guard !Task.isCancelled else { return }
                self.publish(Set(self.highlights.flatMap(\.commentIDs)))
            } catch {
                guard !Task.isCancelled else { return }
                Logger.preview.error("Comment highlights couldn't be updated: \(error.localizedDescription)")
                self.matchedQuotes = nil
                self.highlights = []
                self.publish([])
            }
        }
    }

    private func publish(_ ids: Set<Int64>, force: Bool = false) {
        guard force || linkedIDs != ids else { return }
        linkedIDs = ids
        let file = file
        Task { @MainActor [weak self] in
            guard let self, self.file == file, self.linkedIDs == ids else { return }
            self.onLinkedIDs?(ids)
        }
    }
}
#endif
