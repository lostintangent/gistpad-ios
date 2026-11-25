#if os(iOS)
import Comments
import OSLog
import UIKit
import WebKit

final class CommentHighlighter {
    weak var webView: WKWebView?
    private var file: PreviewFile?
    private var renderedFile: PreviewFile?
    private var comments: CommentHighlights?
    private var accent = ""
    private var segments: [String]?
    private var highlights: [CommentQuoteHighlight] = []
    private var linkedIDs: Set<Int64>?
    private var task: Task<Void, Never>?

    func update(file: PreviewFile, comments: CommentHighlights?, accent: String) {
        let needsInitialReport = self.comments == nil && comments != nil
        let changed = self.file != file || self.comments != comments || self.accent != accent
        if self.file != file {
            reset()
            self.file = file
        }
        self.comments = comments
        self.accent = accent
        if needsInitialReport, let linkedIDs { publish(linkedIDs, force: true) }
        if changed, renderedFile == file { refresh() }
    }

    func rendered(_ file: PreviewFile) {
        guard self.file == file else { return }
        renderedFile = file
        refresh()
    }

    func activate(segment: Int, start: Int, end: Int) throws {
        guard let file, renderedFile == file else { return }
        guard let highlight = highlights.first(where: {
            $0.segment == segment && $0.start == start && $0.end == end
        }) else { throw PreviewError.invalidMessage }
        comments?.open(highlight.threadIDs)
    }

    func addCommentMenu() -> UIDeferredMenuElement? {
        guard comments != nil, let file, renderedFile == file else { return nil }
        return .uncached { [weak self] completion in
            Task {
                guard let self, let webView = self.webView else { return completion([]) }
                do {
                    let value = try await webView.callAsyncJavaScript(
                        "return window.gistpadPreview.commentSelection();",
                        arguments: [:], in: nil, contentWorld: .page)
                    guard self.renderedFile == file, let quote = value as? String,
                          CommentQuote.isQuotable(quote) else { return completion([]) }
                    let action = UIAction(
                        title: String(localized: "Add Comment", bundle: .module),
                        image: UIImage(systemName: "text.bubble")
                    ) { [weak self] _ in
                        guard let self, self.renderedFile == file else { return }
                        self.comments?.add(quote)
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
        highlights = []
        linkedIDs = nil
    }

    private func refresh() {
        task?.cancel()
        guard let file, renderedFile == file, let webView else { return }
        let comments = comments
        let quotes = comments?.quotes ?? []
        let accent = accent
        if quotes.isEmpty, highlights.isEmpty {
            publish([])
            return
        }
        task = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                if !quotes.isEmpty, self.segments == nil {
                    let value = try await webView.callAsyncJavaScript(
                        "return window.gistpadPreview.commentSegments();",
                        arguments: [:], in: nil, contentWorld: .page)
                    guard let segments = value as? [String] else { throw PreviewError.invalidMessage }
                    guard !Task.isCancelled else { return }
                    self.segments = segments
                }
                self.highlights = quotes.highlights(in: self.segments ?? [])
                let payload: [String: Any] = [
                    "highlights": self.highlights.map {
                        ["segment": $0.segment, "start": $0.start, "end": $0.end, "threadIDs": $0.threadIDs]
                    },
                    "selectedThreadID": comments?.selectedThreadID.map { $0 as Any } ?? NSNull(),
                    "revealRevision": comments?.revealRevision ?? 0,
                    "showsInlineComments": comments?.showsInlineComments ?? true,
                    "accent": accent
                ]
                // The page reveals the selected passage itself, and WebKit centers it between the bars.
                _ = try await webView.callAsyncJavaScript(
                    "window.gistpadPreview.setCommentHighlights(payload);",
                    arguments: ["payload": payload], in: nil, contentWorld: .page)
                guard !Task.isCancelled else { return }
                self.publish(Set(self.highlights.flatMap(\.threadIDs)))
            } catch {
                guard !Task.isCancelled else { return }
                Logger.preview.error("Comment highlights couldn't be updated: \(error.localizedDescription)")
                self.highlights = []
                self.publish([])
            }
        }
    }

    private func publish(_ ids: Set<Int64>, force: Bool = false) {
        guard force || linkedIDs != ids else { return }
        linkedIDs = ids
        let file = file
        Task { [weak self] in
            guard let self, self.file == file, self.linkedIDs == ids else { return }
            self.comments?.linked(ids)
        }
    }
}
#endif
