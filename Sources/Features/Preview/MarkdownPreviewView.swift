#if os(iOS)
import SwiftUI
import WebKit
import OSLog
import UniformTypeIdentifiers
import Appearance
import Comments

public struct MarkdownPreviewView: View {
    private let file: PreviewFile
    private let comments: CommentHighlightConfiguration
    private let commentActions: CommentHighlightActions?
    private let onEvent: @MainActor (PreviewEvent) -> Void

    public init(
        markdown: String,
        fileID: String,
        generation: UInt64,
        allowsTaskEdits: Bool = true,
        comments: CommentHighlightConfiguration = .init(),
        commentActions: CommentHighlightActions? = nil,
        onEvent: @escaping @MainActor (PreviewEvent) -> Void
    ) {
        self.file = PreviewFile(
            text: markdown, id: fileID, generation: generation, allowsTaskEdits: allowsTaskEdits)
        self.comments = comments
        self.commentActions = commentActions
        self.onEvent = onEvent
    }

    public var body: some View {
        NativeMarkdownPreview(
            file: file, comments: comments, commentActions: commentActions, onEvent: onEvent
        )
        // The page scrolls under the bars, and UIKit insets it by their height.
        .ignoresSafeArea(.container, edges: .vertical)
        // Resize in one step so WebKit's scroll anchoring keeps the reading passage.
        .transaction { $0.animation = nil }
    }
}

private struct NativeMarkdownPreview: UIViewRepresentable {
    let file: PreviewFile
    let comments: CommentHighlightConfiguration
    let commentActions: CommentHighlightActions?
    let onEvent: @MainActor (PreviewEvent) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accent) private var accent
    @Environment(\.isPaneVisible) private var isPaneVisible

    func makeCoordinator() -> Coordinator {
        Coordinator(file: file, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> PreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PreviewResourceHandler(), forURLScheme: "gistpad-preview")
        configuration.userContentController.add(context.coordinator, name: "gistpadPreview")

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.topEdgeEffect.style = .soft
        webView.scrollView.bottomEdgeEffect.style = .soft
        webView.allowsLinkPreview = false
        webView.scrollView.delegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.commentHighlights.webView = webView
        let coordinator = context.coordinator
        webView.onBuildCommentMenu = { [weak coordinator] in coordinator?.commentHighlights.addCommentMenu() }
        webView.load(URLRequest(url: PreviewResourceHandler.pageURL))
        return webView
    }

    func updateUIView(_ webView: PreviewWebView, context: Context) {
        webView.isHidden = !isPaneVisible
        webView.accessibilityElementsHidden = !isPaneVisible
        context.coordinator.onEvent = onEvent
        let traits = webView.traitCollection.modifyingTraits {
            $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            $0.accessibilityContrast = contrast == .increased ? .high : .normal
            $0.preferredContentSizeCategory = UIContentSizeCategory(dynamicTypeSize)
            $0[AccentTrait.self] = accent
        }
        context.coordinator.appearance = PreviewAppearance(traits: traits, boldText: legibilityWeight == .bold)
        context.coordinator.commentHighlights.update(
            file: file, configuration: comments, actions: commentActions, accent: accent.color.hex)
        context.coordinator.update(file)
    }

    static func dismantleUIView(_ uiView: PreviewWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "gistpadPreview")
        coordinator.commentHighlights.reset()
        uiView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
        fileprivate weak var webView: WKWebView?
        fileprivate var onEvent: @MainActor (PreviewEvent) -> Void
        fileprivate var appearance: PreviewAppearance?
        fileprivate let commentHighlights = PreviewCommentHighlights()
        private var file: PreviewFile
        private var lastSent: PreviewFile?
        private var lastAppearance: PreviewAppearance?
        private var lastViewportInsets: UIEdgeInsets?
        private var ready = false
        private var needsInitialScroll = true

        fileprivate init(file: PreviewFile, onEvent: @escaping @MainActor (PreviewEvent) -> Void) {
            self.file = file
            self.onEvent = onEvent
        }

        /// The completion-handler form submits calls in order, so a later render never races an earlier one.
        private func call(_ script: String, _ arguments: [String: Any] = [:], then: (@MainActor () -> Void)? = nil) {
            webView?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                switch result {
                case .success: then?()
                case .failure(let error): self?.fail(error)
                }
            }
        }

        private func fail(_ error: any Error) {
            let error = error as NSError
            onEvent(.failure(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription))
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            updateViewport()
        }

        /// Anchors and revealed passages land below the bars UIKit insets the page by.
        private func updateViewport() {
            guard ready, let insets = webView?.scrollView.adjustedContentInset, lastViewportInsets != insets else { return }
            lastViewportInsets = insets
            call("window.gistpadPreview.setViewportInsets(payload);",
                 ["payload": ["top": insets.top, "bottom": insets.bottom]])
        }

        fileprivate func update(_ file: PreviewFile) {
            if self.file.id != file.id {
                needsInitialScroll = true
            }
            self.file = file
            guard ready else { return }
            updateViewport()
            if let appearance, appearance != lastAppearance {
                lastAppearance = appearance
                call("window.gistpadPreview.setAppearance(payload);", ["payload": appearance.arguments])
            }
            guard lastSent != file else { return }
            lastSent = file
            call("window.gistpadPreview.render(payload);", ["payload": file.arguments])
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "gistpad-preview",
                  message.frameInfo.securityOrigin.host == "bundle" else {
                Logger.preview.error("Ignored a message from outside the preview bundle.")
                return
            }
            do {
                switch try PreviewBridge.decode(message.body, file: file) {
                case .ready:
                    ready = true
                    update(file)
                case .event(let event):
                    onEvent(event)
                case .commentActivate(let segment, let start, let end):
                    try commentHighlights.activate(segment: segment, start: start, end: end)
                case .rendered:
                    guard needsInitialScroll else {
                        commentHighlights.rendered(file)
                        return
                    }
                    let rendered = file
                    // Initial CSS metrics can still reset WebKit's scroll origin, so wait for layout to settle.
                    call("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));") { [weak self] in
                        guard let self, let webView = self.webView, self.file == rendered else { return }
                        if self.needsInitialScroll {
                            webView.layoutIfNeeded()
                            if !webView.scrollView.isTracking, !webView.scrollView.isDecelerating {
                                let insets = webView.scrollView.adjustedContentInset
                                webView.scrollView.setContentOffset(
                                    CGPoint(x: -insets.left, y: -insets.top), animated: false
                                )
                            }
                            self.needsInitialScroll = false
                        }
                        self.commentHighlights.rendered(rendered)
                    }
                case nil:
                    Logger.preview.debug("Dropped a preview message for an older generation.")
                }
            } catch {
                Logger.preview.error("Ignored an invalid preview message: \(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let allowed = url?.scheme == "gistpad-preview" && url?.host == "bundle" &&
                navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
            return allowed ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            lastSent = nil
            lastAppearance = nil
            lastViewportInsets = nil
            commentHighlights.reset()
            needsInitialScroll = true
            // Crash recovery leaves about:blank, so reload() would bounce on an empty page.
            webView.load(URLRequest(url: PreviewResourceHandler.pageURL))
        }
    }
}

extension Logger {
    static let preview = Logger(subsystem: "dev.gistpad.GistPad", category: "MarkdownPreview")
}

@MainActor
private final class PreviewWebView: WKWebView {
    var onBuildCommentMenu: (() -> UIDeferredMenuElement?)?

    // The preview stays inside the horizontal safe area, but a narrowing frame can overlap it
    // for one layout pass, and that brief inset stops WebKit anchoring the reading position.
    override var safeAreaInsets: UIEdgeInsets {
        let insets = super.safeAreaInsets
        return UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
    }

    override var frame: CGRect {
        willSet {
            guard newValue.width != frame.width, window != nil else { return }
            // WebKit drops its scroll anchor when a reflow clamps the offset, so keep room
            // below the page until the new width has been anchored.
            evaluateJavaScript("""
                {
                  const room = document.body.appendChild(document.createElement("div"));
                  room.style.cssText = `height: ${document.documentElement.scrollHeight}px; overflow-anchor: none`;
                  addEventListener("resize", () => requestAnimationFrame(() =>
                    requestAnimationFrame(() => room.remove())), { once: true });
                }
                """)
        }
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let comment = onBuildCommentMenu?() else { return }
        builder.insertSibling(
            UIMenu(options: .displayInline, children: [comment]), afterMenu: .standardEdit)
    }
}

@MainActor
final class PreviewResourceHandler: NSObject, WKURLSchemeHandler {
    static let pageURL = URL(string: "gistpad-preview://bundle/index.html")!

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url,
                  url.scheme == "gistpad-preview", url.host == "bundle",
                  let base = Bundle.module.url(forResource: "Web", withExtension: nil) else {
                throw PreviewError("Invalid preview resource URL.")
            }
            let file = base.appendingPathComponent(url.path.dropFirst().description).standardizedFileURL
            guard file.path.hasPrefix(base.standardizedFileURL.path + "/") else {
                throw PreviewError("The preview resource is outside its bundle.")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let response = URLResponse(
                url: url,
                mimeType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                expectedContentLength: data.count, textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
