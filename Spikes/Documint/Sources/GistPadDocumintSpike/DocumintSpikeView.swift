#if os(iOS)
import GistPadAppearance
import GistPadEditor
import SwiftUI
import UIKit
import WebKit

public struct DocumintSpikeView: UIViewRepresentable {
    private let session: DocumentSession
    private let onFailure: @MainActor (String) -> Void
    private let onRendered: @MainActor (Double) -> Void
    private let isActive: Bool
    @Environment(\.personalAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        session: DocumentSession,
        isActive: Bool = true,
        onFailure: @escaping @MainActor (String) -> Void,
        onRendered: @escaping @MainActor (Double) -> Void = { _ in }
    ) {
        self.session = session
        self.isActive = isActive
        self.onFailure = onFailure
        self.onRendered = onRendered
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onFailure: onFailure, onRendered: onRendered)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(DocumintResources(), forURLScheme: "gistpad-documint")
        configuration.userContentController.add(context.coordinator, name: "gistpadDocumint")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        view.allowsLinkPreview = false
        view.isInspectable = true
        view.isHidden = !isActive
        view.accessibilityElementsHidden = !isActive
        context.coordinator.webView = view
        view.load(URLRequest(url: URL(string: "gistpad-documint://bundle/index.html")!))
        return view
    }

    public func updateUIView(_ view: WKWebView, context: Context) {
        view.isHidden = !isActive
        view.accessibilityElementsHidden = !isActive
        let traits = view.traitCollection.modifyingTraits {
            $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            $0.preferredContentSizeCategory = dynamicTypeSize.category
            $0.accessibilityContrast = contrast == .increased ? .high : .normal
            $0[PersonalAccentTrait.self] = accent
        }
        context.coordinator.onFailure = onFailure
        context.coordinator.onRendered = onRendered
        context.coordinator.update(traits: traits)
        context.coordinator.setActive(isActive)
    }

    public static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "gistpadDocumint")
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.webView = nil
    }

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        let session: DocumentSession
        var onFailure: @MainActor (String) -> Void
        var onRendered: @MainActor (Double) -> Void
        private var ready = false
        private var sentGeneration: UInt64?
        private var lastRevision = 0
        private var appearance: [String: Any] = [:]
        private var active = true

        init(
            session: DocumentSession, onFailure: @escaping @MainActor (String) -> Void,
            onRendered: @escaping @MainActor (Double) -> Void
        ) {
            self.session = session
            self.onFailure = onFailure
            self.onRendered = onRendered
        }

        func update(traits: UITraitCollection) {
            let roles = traits[PersonalAccentTrait.self].roles(traits: traits)
            func hex(_ color: UIColor) -> String {
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil)
                return String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
                    Int((green * 255).rounded()), Int((blue * 255).rounded()))
            }
            appearance = [
                "dark": traits.userInterfaceStyle == .dark,
                "bodySize": UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize,
                "text": hex(.label), "muted": hex(.secondaryLabel),
                "background": hex(.systemBackground), "surface": hex(.secondarySystemBackground),
                "border": hex(.opaqueSeparator), "blue": hex(.systemBlue),
                "accentText": roles.text.hex, "accentFill": roles.fill.hex, "onAccent": roles.onFill.hex
            ]
            synchronize()
        }

        func setActive(_ next: Bool) {
            guard active != next else { return }
            active = next
            guard !next, ready, let webView else { return }
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "document.activeElement?.blur(); window.gistpadDocumint.flush();",
                        arguments: [:], in: nil, contentWorld: .page
                    )
                } catch { self?.onFailure(error.localizedDescription) }
            }
        }

        private func synchronize() {
            guard ready, let webView else { return }
            let appearance = appearance
            let generation = session.generation
            let needsDocument = sentGeneration != generation
            let document: [String: Any] = [
                "documentID": session.documentID, "generation": String(generation), "markdown": session.text
            ]
            if needsDocument { sentGeneration = generation }
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "if (Object.keys(appearance).length) window.gistpadDocumint.setAppearance(appearance); if (sendDocument) window.gistpadDocumint.setDocument(document);",
                        arguments: ["appearance": appearance, "document": document, "sendDocument": needsDocument],
                        in: nil, contentWorld: .page
                    )
                } catch {
                    self?.onFailure(error.localizedDescription)
                }
            }
        }

        public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "gistpad-documint",
                  message.frameInfo.securityOrigin.host == "bundle"
            else { onFailure(DocumintBridge.Failure.invalidMessage.localizedDescription); return }
            do {
                let event = try DocumintBridge.decode(message.body)
                switch event.type {
                case "ready":
                    ready = true
                    synchronize()
                case "changed":
                    guard event.documentID == session.documentID,
                          event.generation == String(session.generation),
                          event.revision == lastRevision + 1,
                          let markdown = event.markdown, let revision = event.revision
                    else { throw DocumintBridge.Failure.staleRevision }
                    if let mutation = DocumintBridge.mutation(from: session.text, to: markdown) {
                        try session.apply(mutation, documentID: session.documentID, generation: session.generation)
                    }
                    lastRevision = revision
                    sentGeneration = session.generation
                    acknowledge(revision: revision, generation: session.generation)
                case "rendered":
                    if let milliseconds = event.milliseconds, milliseconds.isFinite, milliseconds >= 0 {
                        onRendered(milliseconds)
                    }
                case "failure":
                    onFailure(String((event.message ?? "The rich editor failed.").prefix(512)))
                default: throw DocumintBridge.Failure.invalidMessage
                }
            } catch {
                onFailure(error.localizedDescription)
            }
        }

        private func acknowledge(revision: Int, generation: UInt64) {
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "window.gistpadDocumint.acknowledge(revision, generation);",
                        arguments: ["revision": revision, "generation": String(generation)],
                        in: nil, contentWorld: .page
                    )
                } catch { self?.onFailure(error.localizedDescription) }
            }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            return url?.scheme == "gistpad-documint" && url?.host == "bundle"
                && navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
                ? .allow : .cancel
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFailure(error.localizedDescription)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure(error.localizedDescription)
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            onFailure(DocumintBridge.Failure.stopped.localizedDescription)
        }
    }
}

@MainActor
final class DocumintResources: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == "gistpad-documint", url.host == "bundle",
                  let root = Bundle.module.url(forResource: "Web", withExtension: nil),
                  !url.path.contains("\\"), !url.pathComponents.contains("..")
            else { throw DocumintBridge.Failure.invalidMessage }
            let file = root.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  ["index.html", "editor.js", "pixel.svg", "pixel.png", "parity.md", "provenance.json"].contains(file.lastPathComponent)
            else { throw DocumintBridge.Failure.invalidMessage }
            let data = try Data(contentsOf: file)
            let mime = ["html": "text/html", "js": "application/javascript",
                "svg": "image/svg+xml", "png": "image/png", "json": "application/json"][file.pathExtension]
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": mime ?? "text/plain",
                    "Content-Length": String(data.count)])
            else { throw DocumintBridge.Failure.invalidMessage }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

public enum DocumintSpikeFixtures {
    public static var markdown: String {
        get throws {
            guard let url = Bundle.module.url(forResource: "parity", withExtension: "md", subdirectory: "Web")
            else { throw DocumintBridge.Failure.invalidMessage }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }
}

private extension DynamicTypeSize {
    var category: UIContentSizeCategory {
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
#endif
