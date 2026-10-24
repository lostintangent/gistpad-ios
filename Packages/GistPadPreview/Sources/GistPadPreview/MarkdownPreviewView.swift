#if os(iOS)
import SwiftUI
import WebKit
import OSLog
import GistPadAppearance

public struct MarkdownPreviewView: View {
    private let document: PreviewDocument
    private let allowsTaskEdits: Bool
    private let onEvent: @MainActor (PreviewEvent) -> Void

    public init(
        document: String,
        documentID: String,
        generation: UInt64,
        allowsTaskEdits: Bool = true,
        onEvent: @escaping @MainActor (PreviewEvent) -> Void
    ) {
        self.document = PreviewDocument(text: document, id: documentID, generation: generation)
        self.allowsTaskEdits = allowsTaskEdits
        self.onEvent = onEvent
    }

    public var body: some View {
        GeometryReader { geometry in
            NativeMarkdownPreview(
                document: document, allowsTaskEdits: allowsTaskEdits,
                verticalInsets: geometry.safeAreaInsets, onEvent: onEvent
            )
            .ignoresSafeArea(.container, edges: .vertical)
        }
    }
}

private struct NativeMarkdownPreview: UIViewRepresentable {
    let document: PreviewDocument
    let allowsTaskEdits: Bool
    let verticalInsets: EdgeInsets
    let onEvent: @MainActor (PreviewEvent) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.personalAccent) private var personalAccent

    init(
        document: PreviewDocument, allowsTaskEdits: Bool, verticalInsets: EdgeInsets,
        onEvent: @escaping @MainActor (PreviewEvent) -> Void
    ) {
        self.document = document
        self.allowsTaskEdits = allowsTaskEdits
        self.verticalInsets = verticalInsets
        self.onEvent = onEvent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, allowsTaskEdits: allowsTaskEdits, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> InsetAwareWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(PreviewResourceHandler(), forURLScheme: "gistpad-preview")
        configuration.userContentController.add(context.coordinator, name: "gistpadPreview")

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
        let coordinator = context.coordinator
        webView.onViewportChange = { [weak coordinator] in coordinator?.updateViewport($0) }
        webView.updateVerticalInsets(verticalInsets)
        webView.load(URLRequest(url: URL(string: "gistpad-preview://bundle/index.html")!))
        return webView
    }

    func updateUIView(_ webView: InsetAwareWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        webView.updateVerticalInsets(verticalInsets)
        let traits = webView.traitCollection.modifyingTraits {
            $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            $0.accessibilityContrast = contrast == .increased ? .high : .normal
            $0.preferredContentSizeCategory = dynamicTypeSize.contentSizeCategory
            $0[PersonalAccentTrait.self] = personalAccent
        }
        context.coordinator.appearance = PreviewAppearance(traits: traits, boldText: legibilityWeight == .bold)
        context.coordinator.update(document, allowsTaskEdits: allowsTaskEdits)
    }

    static func dismantleUIView(_ uiView: InsetAwareWebView, coordinator: Coordinator) {
        uiView.onViewportChange = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "gistpadPreview")
        uiView.navigationDelegate = nil
        coordinator.webView = nil
        uiView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        fileprivate weak var webView: WKWebView?
        fileprivate var onEvent: @MainActor (PreviewEvent) -> Void
        fileprivate var appearance: PreviewAppearance?
        private var document: PreviewDocument
        private var allowsTaskEdits: Bool
        private var lastSent: PreviewDocument?
        private var lastTaskEditing: Bool?
        private var lastAppearance: PreviewAppearance?
        private var viewportInsets = UIEdgeInsets.zero
        private var lastViewportInsets: UIEdgeInsets?
        private var ready = false
        private var needsInitialScroll = true

        fileprivate init(document: PreviewDocument, allowsTaskEdits: Bool, onEvent: @escaping @MainActor (PreviewEvent) -> Void) {
            self.document = document
            self.allowsTaskEdits = allowsTaskEdits
            self.onEvent = onEvent
        }

        fileprivate func updateViewport(_ insets: UIEdgeInsets) {
            viewportInsets = insets
            guard ready, let webView, lastViewportInsets != insets else { return }
            lastViewportInsets = insets
            Task { @MainActor [weak self, weak webView] in
                guard let webView, self?.viewportInsets == insets else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "window.gistpadPreview.setViewportInsets(payload);",
                        arguments: ["payload": ["top": insets.top, "bottom": insets.bottom]],
                        in: nil, contentWorld: .page
                    )
                } catch {
                    self?.lastViewportInsets = nil
                    self?.onEvent(.failure(.webKit(error)))
                }
            }
        }

        fileprivate func update(_ document: PreviewDocument, allowsTaskEdits: Bool) {
            if self.document.id != document.id {
                needsInitialScroll = true
            }
            self.document = document
            self.allowsTaskEdits = allowsTaskEdits
            guard ready, let webView else { return }
            updateViewport(viewportInsets)
            do {
                try document.validate()
            } catch let failure as PreviewFailure {
                onEvent(.failure(failure))
                return
            } catch {
                onEvent(.failure(.renderer(error.localizedDescription)))
                return
            }
            if lastTaskEditing != allowsTaskEdits {
                lastTaskEditing = allowsTaskEdits
                Task { @MainActor [weak self, weak webView] in
                    guard let webView, self?.allowsTaskEdits == allowsTaskEdits else { return }
                    do {
                        _ = try await webView.callAsyncJavaScript(
                            "window.gistpadPreview.setTaskEditingEnabled(enabled);",
                            arguments: ["enabled": allowsTaskEdits],
                            in: nil, contentWorld: .page
                        )
                    } catch {
                        self?.lastTaskEditing = nil
                        self?.onEvent(.failure(.webKit(error)))
                    }
                }
            }
            if let appearance, appearance != lastAppearance {
                lastAppearance = appearance
                Task { @MainActor [weak self, weak webView] in
                    guard let webView else { return }
                    do {
                        // Initial CSS metrics can still reset WebKit's native scroll origin.
                        _ = try await webView.callAsyncJavaScript(
                            "window.gistpadPreview.setAppearance(payload);",
                            arguments: ["payload": appearance.arguments],
                            in: nil, contentWorld: .page
                        )
                    } catch {
                        self?.lastAppearance = nil
                        self?.onEvent(.failure(.webKit(error)))
                    }
                }
            }
            guard lastSent != document else { return }
            lastSent = document
            Task { @MainActor [weak self, weak webView] in
                guard let webView, self?.document == document else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "window.gistpadPreview.render(payload);",
                        arguments: ["payload": document.arguments],
                        in: nil, contentWorld: .page
                    )
                } catch {
                    self?.lastSent = nil
                    self?.onEvent(.failure(.webKit(error)))
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "gistpad-preview",
                  message.frameInfo.securityOrigin.host == "bundle" else {
                onEvent(.failure(.invalidMessage))
                return
            }
            do {
                switch try PreviewBridge.decode(message.body, document: document, allowsTaskEdits: allowsTaskEdits) {
                case .ready:
                    ready = true
                    update(document, allowsTaskEdits: allowsTaskEdits)
                case .obsolete:
                    Logger(subsystem: "dev.gistpad.GistPad", category: "MarkdownPreview")
                        .debug("Discarded a passive preview event from an obsolete document generation.")
                case .taskEditingUnavailable:
                    Logger(subsystem: "dev.gistpad.GistPad", category: "MarkdownPreview")
                        .debug("Discarded a task edit after preview editing became unavailable.")
                case .event(let event):
                    if case .rendered(let id, let generation) = event, needsInitialScroll, let webView {
                        Task { @MainActor [weak self, weak webView] in
                            guard let webView else { return }
                            do {
                                _ = try await webView.callAsyncJavaScript(
                                    "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));",
                                    arguments: [:], in: nil, contentWorld: .page
                                )
                                guard let self, self.document.id == id, self.document.generation == generation else { return }
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
                                self.onEvent(event)
                            } catch {
                                self?.onEvent(.failure(.webKit(error)))
                            }
                        }
                    } else {
                        onEvent(event)
                    }
                }
            } catch let failure as PreviewFailure {
                onEvent(.failure(failure))
            } catch {
                onEvent(.failure(.renderer(error.localizedDescription)))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let allowed = url?.scheme == "gistpad-preview" && url?.host == "bundle" &&
                navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
            return allowed ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onEvent(.failure(.renderer(error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onEvent(.failure(.renderer(error.localizedDescription)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            lastSent = nil
            lastTaskEditing = nil
            lastAppearance = nil
            lastViewportInsets = nil
            needsInitialScroll = true
            onEvent(.failure(.renderer("The preview stopped unexpectedly. Reload the document to recover.")))
            webView.reload()
        }
    }
}

@MainActor
private final class InsetAwareWebView: WKWebView {
    var onViewportChange: ((UIEdgeInsets) -> Void)?
    private var verticalInsets = EdgeInsets()
    private var applyingInsets = false

    func updateVerticalInsets(_ insets: EdgeInsets) {
        verticalInsets = insets
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
        guard !applyingInsets else { return }
        applyingInsets = true
        defer { applyingInsets = false }
        let previous = scrollView.adjustedContentInset
        let atTop = abs(scrollView.contentOffset.y + previous.top) <= 1
        let automaticTop = previous.top - scrollView.contentInset.top
        let automaticBottom = previous.bottom - scrollView.contentInset.bottom
        var contentInsets = scrollView.contentInset
        contentInsets.top = max(0, verticalInsets.top - automaticTop)
        contentInsets.bottom = max(0, verticalInsets.bottom - automaticBottom)
        if contentInsets != scrollView.contentInset {
            scrollView.contentInset = contentInsets
            if atTop, !scrollView.isTracking, !scrollView.isDecelerating {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
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
                throw PreviewFailure.renderer("Invalid preview resource URL.")
            }
            let file = base.appendingPathComponent(url.path.dropFirst().description).standardizedFileURL
            guard file.path.hasPrefix(base.standardizedFileURL.path + "/") else {
                throw PreviewFailure.renderer("The preview resource is outside its bundle.")
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
