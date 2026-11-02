#if os(iOS)
import SwiftUI
import WebKit
import OSLog
import GistPadAppearance
import GistPadComments

public struct MarkdownPreviewView: View {
    private let document: PreviewDocument
    private let comments: CommentHighlightConfiguration
    private let onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
    private let onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
    private let onAddComment: (@MainActor (String) -> Void)?
    private let onEvent: @MainActor (PreviewEvent) -> Void
    @State private var viewportView = PreviewViewportView()

    public init(
        document: String,
        documentID: String,
        generation: UInt64,
        allowsTaskEdits: Bool = true,
        comments: CommentHighlightConfiguration = .init(),
        onOpenCommentThreads: (@MainActor ([Int64]) -> Void)? = nil,
        onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)? = nil,
        onAddComment: (@MainActor (String) -> Void)? = nil,
        onEvent: @escaping @MainActor (PreviewEvent) -> Void
    ) {
        self.document = PreviewDocument(
            text: document, id: documentID, generation: generation, allowsTaskEdits: allowsTaskEdits)
        self.comments = comments
        self.onOpenCommentThreads = onOpenCommentThreads
        self.onLinkedCommentIDsChange = onLinkedCommentIDsChange
        self.onAddComment = onAddComment
        self.onEvent = onEvent
    }

    public var body: some View {
        GeometryReader { _ in
            NativeMarkdownPreview(
                document: document, viewportView: viewportView, comments: comments,
                onOpenCommentThreads: onOpenCommentThreads,
                onLinkedCommentIDsChange: onLinkedCommentIDsChange,
                onAddComment: onAddComment, onEvent: onEvent
            )
            .ignoresSafeArea(.container, edges: .vertical)
            // Resize in one step so WebKit's scroll anchoring keeps the reading passage.
            .transaction { $0.animation = nil }
        }
        .overlay { PreviewViewport(view: viewportView).allowsHitTesting(false) }
    }
}

private struct NativeMarkdownPreview: UIViewRepresentable {
    let document: PreviewDocument
    let viewportView: PreviewViewportView
    let comments: CommentHighlightConfiguration
    let onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
    let onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
    let onAddComment: (@MainActor (String) -> Void)?
    let onEvent: @MainActor (PreviewEvent) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.personalAccent) private var personalAccent
    @Environment(\.isNotebookPaneVisible) private var isPaneVisible

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> InsetAwareWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(PreviewResourceHandler(), forURLScheme: "gistpad-preview")
        configuration.userContentController.add(context.coordinator, name: "gistpadPreview")
        configuration.userContentController.add(context.coordinator, name: "gistpadComments")

        let webView = InsetAwareWebView(frame: .zero, configuration: configuration)
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
        context.coordinator.webView = webView
        context.coordinator.commentHighlights.webView = webView
        let coordinator = context.coordinator
        webView.onBuildCommentMenu = { [weak coordinator] in coordinator?.commentHighlights.addCommentMenu() }
        webView.onViewportChange = { [weak coordinator] in coordinator?.updateViewport($0) }
        viewportView.webView = webView
        webView.updateViewportView(viewportView)
        webView.load(URLRequest(url: URL(string: "gistpad-preview://bundle/index.html")!))
        return webView
    }

    func updateUIView(_ webView: InsetAwareWebView, context: Context) {
        webView.isHidden = !isPaneVisible
        webView.accessibilityElementsHidden = !isPaneVisible
        context.coordinator.onEvent = onEvent
        viewportView.webView = webView
        webView.updateViewportView(viewportView)
        let traits = webView.traitCollection.modifyingTraits {
            $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            $0.accessibilityContrast = contrast == .increased ? .high : .normal
            $0.preferredContentSizeCategory = dynamicTypeSize.contentSizeCategory
            $0[PersonalAccentTrait.self] = personalAccent
        }
        context.coordinator.appearance = PreviewAppearance(traits: traits, boldText: legibilityWeight == .bold)
        context.coordinator.commentHighlights.update(
            document: document, configuration: comments, accent: personalAccent.color.hex,
            onOpen: onOpenCommentThreads, onLinkedIDs: onLinkedCommentIDsChange, onAdd: onAddComment)
        context.coordinator.update(document)
    }

    static func dismantleUIView(_ uiView: InsetAwareWebView, coordinator: Coordinator) {
        uiView.onViewportChange = nil
        uiView.onBuildCommentMenu = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "gistpadPreview")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "gistpadComments")
        coordinator.commentHighlights.reset()
        coordinator.commentHighlights.webView = nil
        uiView.navigationDelegate = nil
        coordinator.webView = nil
        uiView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        fileprivate weak var webView: WKWebView?
        fileprivate var onEvent: @MainActor (PreviewEvent) -> Void
        fileprivate var appearance: PreviewAppearance?
        fileprivate let commentHighlights = PreviewCommentHighlights()
        private var document: PreviewDocument
        private var lastSent: PreviewDocument?
        private var lastAppearance: PreviewAppearance?
        private var viewportInsets = UIEdgeInsets.zero
        private var lastViewportInsets: UIEdgeInsets?
        private var ready = false
        private var needsInitialScroll = true

        fileprivate init(document: PreviewDocument, onEvent: @escaping @MainActor (PreviewEvent) -> Void) {
            self.document = document
            self.onEvent = onEvent
        }

        /// The completion-handler form submits calls in order, so a later render never races an earlier one.
        private func call(_ script: String, _ arguments: [String: Any] = [:], then: (@MainActor () -> Void)? = nil) {
            webView?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                switch result {
                case .success: then?()
                case .failure(let error): self?.onEvent(.failure(PreviewFailure(error)))
                }
            }
        }

        fileprivate func updateViewport(_ insets: UIEdgeInsets) {
            viewportInsets = insets
            guard ready, lastViewportInsets != insets else { return }
            lastViewportInsets = insets
            call("window.gistpadPreview.setViewportInsets(payload);",
                 ["payload": ["top": insets.top, "bottom": insets.bottom]])
        }

        fileprivate func update(_ document: PreviewDocument) {
            if self.document.id != document.id {
                needsInitialScroll = true
            }
            self.document = document
            guard ready else { return }
            updateViewport(viewportInsets)
            if let appearance, appearance != lastAppearance {
                lastAppearance = appearance
                call("window.gistpadPreview.setAppearance(payload);", ["payload": appearance.arguments])
            }
            guard lastSent != document else { return }
            lastSent = document
            call("window.gistpadPreview.render(payload);", ["payload": document.arguments])
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "gistpad-preview",
                  message.frameInfo.securityOrigin.host == "bundle" else {
                Logger.preview.error("Ignored a message from outside the preview bundle.")
                return
            }
            do {
                if message.name == "gistpadComments" {
                    try commentHighlights.activate(message.body)
                    return
                }
                switch try PreviewBridge.decode(message.body, document: document) {
                case .ready:
                    ready = true
                    update(document)
                case .event(let event):
                    guard case .rendered = event, needsInitialScroll else {
                        if case .rendered = event { commentHighlights.rendered(document) }
                        onEvent(event)
                        return
                    }
                    let rendered = document
                    // Initial CSS metrics can still reset WebKit's scroll origin, so wait for layout to settle.
                    call("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));") { [weak self] in
                        guard let self, let webView = self.webView, self.document == rendered else { return }
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
                        self.onEvent(event)
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
            onEvent(.failure(PreviewFailure(error)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onEvent(.failure(PreviewFailure(error)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            lastSent = nil
            lastAppearance = nil
            lastViewportInsets = nil
            commentHighlights.reset()
            needsInitialScroll = true
            webView.reload()
        }
    }
}

extension Logger {
    static let preview = Logger(subsystem: "dev.gistpad.GistPad", category: "MarkdownPreview")
}

@MainActor
private struct PreviewViewport: UIViewRepresentable {
    let view: PreviewViewportView

    func makeUIView(context: Context) -> PreviewViewportView { view }
    func updateUIView(_ view: PreviewViewportView, context: Context) {}
}

@MainActor
private final class PreviewViewportView: UIView {
    weak var webView: InsetAwareWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        webView?.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView?.setNeedsLayout()
    }
}

@MainActor
private final class InsetAwareWebView: WKWebView {
    var onViewportChange: ((UIEdgeInsets) -> Void)?
    var onBuildCommentMenu: (() -> UIDeferredMenuElement?)?
    private weak var viewportView: UIView?
    private var applyingInsets = false

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

    func updateViewportView(_ view: UIView) {
        viewportView = view
        updateContentInsets()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateContentInsets()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInsets()
    }

    private func updateContentInsets() {
        guard !applyingInsets, let viewportView, window != nil, viewportView.window === window else { return }
        applyingInsets = true
        defer { applyingInsets = false }
        let previous = scrollView.adjustedContentInset
        let readingOffset = scrollView.contentOffset.y + previous.top
        let automaticTop = previous.top - scrollView.contentInset.top
        let automaticBottom = previous.bottom - scrollView.contentInset.bottom
        let viewport = convert(viewportView.bounds, from: viewportView)
        var contentInsets = scrollView.contentInset
        contentInsets.top = max(0, viewport.minY - bounds.minY - automaticTop)
        contentInsets.bottom = max(0, bounds.maxY - viewport.maxY - automaticBottom)
        if contentInsets != scrollView.contentInset {
            scrollView.contentInset = contentInsets
            if !scrollView.isTracking, !scrollView.isDecelerating {
                let insets = scrollView.adjustedContentInset
                let minimum = -insets.top
                let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: min(maximum, max(minimum, readingOffset - insets.top))),
                    animated: false
                )
            }
        }
        onViewportChange?(scrollView.adjustedContentInset)
    }
}

private extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

@MainActor
final class PreviewResourceHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url,
                  url.scheme == "gistpad-preview", url.host == "bundle",
                  let base = Bundle.module.url(forResource: "Web", withExtension: nil),
                  !url.path.contains("\\"),
                  !url.pathComponents.contains("..") else {
                throw PreviewFailure("Invalid preview resource URL.")
            }
            let file = base.appendingPathComponent(url.path.dropFirst().description).standardizedFileURL
            guard file.path.hasPrefix(base.standardizedFileURL.path + "/") else {
                throw PreviewFailure("The preview resource is outside its bundle.")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let mimeTypes = ["html": "text/html", "js": "application/javascript", "css": "text/css",
                             "json": "application/json", "svg": "image/svg+xml", "png": "image/png"]
            let response = URLResponse(
                url: url, mimeType: mimeTypes[file.pathExtension] ?? "application/octet-stream",
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
