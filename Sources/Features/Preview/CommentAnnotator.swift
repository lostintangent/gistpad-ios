#if os(iOS)
import Comments
import OSLog
import SwiftUI
import UIKit
import WebKit

final class CommentAnnotator {
    /// What the page annotates, and who hears about taps, quotes and matches.
    struct Input {
        var comments: DocumentComments?
        var scrollPosition: ScrollPosition
        var openThreads: @MainActor ([Int64]) -> Void
        var addComment: @MainActor (String) -> Void
        var matched: @MainActor (Set<Int64>) -> Void
    }

    weak var webView: WKWebView?
    private var file: PreviewFile?
    private var renderedFile: PreviewFile?
    private var input: Input?
    private var comments: DocumentComments? { input?.comments }
    private var accent = ""
    /// The thread the position last scrolled to, counted so the page reveals each scroll once.
    private var reveal: (threadID: Int64, revision: Int)?
    private var segments: [String]?
    private var annotations: [CommentQuote.Match] = []
    private var matchedIDs: Set<Int64>?
    private var task: Task<Void, Never>?

    func update(file: PreviewFile, input: Input, accent: String) {
        let needsInitialReport = comments == nil && input.comments != nil
        // The first position is where the page starts, so only a later scroll reveals.
        let scrolled = self.input.map { $0.scrollPosition != input.scrollPosition } ?? false
        let changed = self.file != file || comments != input.comments || self.accent != accent || scrolled
        if self.file != file {
            reset()
            self.file = file
        }
        if scrolled, let threadID = input.scrollPosition.viewID(type: Int64.self) {
            reveal = (threadID, (reveal?.revision ?? 0) + 1)
        }
        self.input = input
        self.accent = accent
        if needsInitialReport, let matchedIDs { publish(matchedIDs, force: true) }
        if changed, renderedFile == file { refresh() }
    }

    func rendered(_ file: PreviewFile) {
        guard self.file == file else { return }
        renderedFile = file
        refresh()
    }

    func activate(segment: Int, start: Int, end: Int) throws {
        guard let file, renderedFile == file else { return }
        guard let annotation = annotations.first(where: {
            $0.segment == segment && $0.start == start && $0.end == end
        }) else { throw PreviewError.invalidMessage }
        input?.openThreads(annotation.threadIDs)
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
                        self.input?.addComment(quote)
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
        annotations = []
        matchedIDs = nil
        reveal = nil
    }

    private func refresh() {
        task?.cancel()
        guard let file, renderedFile == file, let webView else { return }
        let comments = comments
        let quotes = comments?.quotes ?? []
        let reveal = reveal
        let accent = accent
        if quotes.isEmpty, annotations.isEmpty {
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
                self.annotations = quotes.matches(in: self.segments ?? [])
                let payload: [String: Any] = [
                    "annotations": self.annotations.map {
                        ["segment": $0.segment, "start": $0.start, "end": $0.end, "threadIDs": $0.threadIDs]
                    },
                    "selectedThreadID": comments?.selectedThreadID.map { $0 as Any } ?? NSNull(),
                    "showsAll": comments?.showsAll ?? true,
                    "reveal": reveal.map { ["threadID": $0.threadID, "revision": $0.revision] as Any } ?? NSNull(),
                    "accent": accent
                ]
                // The page reveals the passage itself, and WebKit centers it between the bars.
                _ = try await webView.callAsyncJavaScript(
                    "window.gistpadPreview.setCommentAnnotations(payload);",
                    arguments: ["payload": payload], in: nil, contentWorld: .page)
                guard !Task.isCancelled else { return }
                self.publish(Set(self.annotations.flatMap(\.threadIDs)))
            } catch {
                guard !Task.isCancelled else { return }
                Logger.preview.error("Comment annotations couldn't be updated: \(error.localizedDescription)")
                self.annotations = []
                self.publish([])
            }
        }
    }

    private func publish(_ ids: Set<Int64>, force: Bool = false) {
        guard force || matchedIDs != ids else { return }
        matchedIDs = ids
        let file = file
        Task { [weak self] in
            guard let self, self.file == file, self.matchedIDs == ids else { return }
            self.input?.matched(ids)
        }
    }
}
#endif
