#if os(iOS)
import Foundation
import Testing
import UIKit
import WebKit
@testable import GistPadPreview

@MainActor
@Suite("Offline WebKit renderer", .serialized)
struct PreviewWebKitTests {
    @Test("The actual bundled page renders and addresses duplicate tasks")
    func offlineRendering() async throws {
        let markdown = try PreviewFixtures.allSyntax
            .replacingOccurrences(of: "![Remote image](https://example.com/gistpad-fixture.png)", with: "")
        let document = PreviewDocument(text: markdown, id: "web-kit-fixture", generation: UInt64.max)
        let receiver = MessageReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PreviewResourceHandler(), forURLScheme: "gistpad-preview")
        configuration.userContentController.add(receiver, name: "gistpadPreview")
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            const report = message => window.webkit.messageHandlers.gistpadPreview.postMessage({type: 'diagnostic', message});
            window.addEventListener('error', event => report(event.message || event.target?.src || 'Resource load error'), true);
            window.addEventListener('unhandledrejection', event => report(String(event.reason)));
            document.addEventListener('securitypolicyviolation', event => report(event.violatedDirective + ': ' + event.blockedURI));
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        webView.navigationDelegate = receiver
        let controller = UIViewController()
        controller.view = webView
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = webView.frame
        } else {
            window = UIWindow(frame: webView.frame)
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "gistpadPreview")
            webView.stopLoading()
            window.isHidden = true
            window.rootViewController = nil
        }
        try #require(webView.load(URLRequest(url: URL(string: "gistpad-preview://bundle/index.html")!)))
        do {
            try await waitFor("ready message") { receiver.bodies.contains { $0["type"] as? String == "ready" } }
        } catch {
            let state = try await webView.callAsyncJavaScript(
                "return {url:location.href,state:document.readyState,renderer:typeof window.gistpadPreview};",
                arguments: [:], in: nil, contentWorld: .page
            )
            let diagnostics = receiver.bodies.filter { $0["type"] as? String == "diagnostic" }
            throw PreviewFailure.renderer("Ready timeout. Page: \(String(describing: state)). Diagnostics: \(diagnostics). Navigation: \(receiver.navigationErrors)")
        }
        #expect(receiver.origins.allSatisfy { $0 == "gistpad-preview://bundle" })
        _ = try await webView.callAsyncJavaScript(
            "window.gistpadPreview.render(payload);",
            arguments: ["payload": document.arguments], in: nil, contentWorld: .page
        )
        try await waitFor("rendered message") { receiver.bodies.contains { $0["type"] as? String == "rendered" } }
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for contrast: UIAccessibilityContrast in [.normal, .high] {
                for size: UIContentSizeCategory in [.large, .accessibilityExtraLarge] {
                    let traits = UITraitCollection {
                        $0.userInterfaceStyle = style
                        $0.accessibilityContrast = contrast
                        $0.preferredContentSizeCategory = size
                    }
                    let appearance = PreviewAppearance(traits: traits)
                    let selectionPreserved = try await webView.callAsyncJavaScript(
                        """
                        const range = document.createRange();
                        range.selectNodeContents(document.querySelector('p'));
                        const selection = window.getSelection();
                        selection.removeAllRanges();
                        selection.addRange(range);
                        const selectedText = selection.toString();
                        window.gistpadPreview.setAppearance(payload);
                        const preserved = selection.toString() === selectedText;
                        selection.removeAllRanges();
                        return preserved;
                        """,
                        arguments: ["payload": appearance.arguments], in: nil, contentWorld: .page
                    ) as? Bool
                    #expect(selectionPreserved == true)
                    let appliedSize = try await webView.callAsyncJavaScript(
                        "return getComputedStyle(document.documentElement).getPropertyValue('--gp-body-size');",
                        arguments: [:], in: nil, contentWorld: .page
                    ) as? String
                    #expect(appliedSize == appearance.variables["--gp-body-size"])
                }
            }
        }
        var diagramRendered = false
        for _ in 0..<200 {
            diagramRendered = try await webView.callAsyncJavaScript(
                "return document.querySelector('svg[id^=\"mermaid-\"]') !== null;",
                arguments: [:], in: nil, contentWorld: .page
            ) as? Bool == true
            if diagramRendered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(diagramRendered)
        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('input[type=checkbox]:not(:disabled)').length;",
            arguments: [:], in: nil, contentWorld: .page
        ) as? Int
        #expect(count == 7)
        let readingPresentation = try await webView.callAsyncJavaScript(
            """
            const outline = document.querySelector('nav[aria-label="Contents"]');
            return outline !== null &&
                [...outline.querySelectorAll('a')].every(anchor =>
                    anchor.getBoundingClientRect().height >= 44 &&
                    getComputedStyle(anchor).textDecorationLine === 'none') &&
                document.querySelectorAll('.markdown-alert-title > svg.alert-symbol').length === 5;
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        #expect(readingPresentation == true)
        _ = try await webView.callAsyncJavaScript(
            "document.querySelectorAll('input[type=checkbox]')[1].click();",
            arguments: [:], in: nil, contentWorld: .page
        )
        try await waitFor("task toggle") { receiver.bodies.contains { $0["type"] as? String == "taskToggle" } }
        let body = try #require(receiver.bodies.last { $0["type"] as? String == "taskToggle" })
        guard case .event(.taskToggle(let edit)) = try PreviewBridge.decode(body, document: document) else {
            Issue.record("Expected a validated source edit")
            return
        }
        #expect(edit.range == (markdown as NSString).range(of: "[x]"))
        #expect(edit.expectedMarker == "[x]")
        #expect(edit.replacementMarker == "[ ]")
        let updated = (markdown as NSString).replacingCharacters(in: edit.range, with: edit.replacementMarker)
        #expect(updated == markdown.replacingOccurrences(of: "- [x] Duplicate task", with: "- [ ] Duplicate task"))
        #expect(receiver.bodies.contains { $0["type"] as? String == "height" })

        for style: UIUserInterfaceStyle in [.light, .dark] {
            for contrast: UIAccessibilityContrast in [.normal, .high] {
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = style
                    $0.accessibilityContrast = contrast
                    $0.preferredContentSizeCategory = .large
                }
                webView.overrideUserInterfaceStyle = style
                let appearance = PreviewAppearance(traits: traits)
                _ = try await webView.callAsyncJavaScript(
                    "window.gistpadPreview.setAppearance(payload);",
                    arguments: ["payload": appearance.arguments], in: nil, contentWorld: .page
                )
                var themeApplied = false
                for _ in 0..<100 {
                    themeApplied = try await webView.callAsyncJavaScript(
                        """
                        const label = document.querySelector('.nodeLabel');
                        if (!label) return false;
                        const values = getComputedStyle(label).color.match(/[\\d.]+/g).slice(0, 3).map(Number);
                        const lightText = values.reduce((sum, value) => sum + value, 0) > 384;
                        return lightText === (document.documentElement.dataset.colorScheme === 'dark');
                        """,
                        arguments: [:], in: nil, contentWorld: .page
                    ) as? Bool == true
                    if themeApplied { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(themeApplied)
                let systemDiagramFont = try await webView.callAsyncJavaScript(
                    "return getComputedStyle(document.querySelector('.nodeLabel')).fontFamily.includes('-apple-system');",
                    arguments: [:], in: nil, contentWorld: .page
                ) as? Bool
                #expect(systemDiagramFont == true)
                let ratios = try await webView.callAsyncJavaScript(
                    """
                    const parse = color => color.match(/[\\d.]+/g).slice(0, 3).map(Number);
                    const luminance = rgb => rgb.map(value => {
                        value /= 255;
                        return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
                    }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
                    const background = luminance(parse(getComputedStyle(document.documentElement).backgroundColor));
                    return ['h1', 'article > p', 'li.task-list-item'].map(selector => {
                        const style = getComputedStyle(document.querySelector(selector));
                        if (style.visibility !== 'visible' || Number(style.opacity) !== 1) return 0;
                        const foreground = luminance(parse(style.color));
                        return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
                    });
                    """,
                    arguments: [:], in: nil, contentWorld: .page
                ) as? [Double]
                #expect(try #require(ratios).allSatisfy { $0 >= 4.5 })
                _ = try await webView.callAsyncJavaScript(
                    "window.scrollTo(0, 0);",
                    arguments: [:], in: nil, contentWorld: .page
                )
                try await Task.sleep(for: .milliseconds(150))
                let snapshot = try await webView.takeSnapshot(configuration: nil)
                Attachment.record(
                    snapshot,
                    named: "duo-webkit-\(style == .dark ? "dark" : "light")-\(contrast == .high ? "increased" : "normal").png",
                    as: .png
                )
                _ = try await webView.callAsyncJavaScript(
                    "document.getElementById('a-small-diagram').scrollIntoView();",
                    arguments: [:], in: nil, contentWorld: .page
                )
                try await Task.sleep(for: .milliseconds(150))
                let diagramSnapshot = try await webView.takeSnapshot(configuration: nil)
                Attachment.record(
                    diagramSnapshot,
                    named: "duo-diagram-\(style == .dark ? "dark" : "light")-\(contrast == .high ? "increased" : "normal").png",
                    as: .png
                )
            }
        }

        let stress = "# A long synthetic note\n" + (0..<500).map { index in
            "\n## Section \(index)\n\nNative source remains canonical. 👩🏽‍💻 café é 日本語のメモ。中文笔记。مرحبا بالعالم. שלום עולם.\n\n- [ ] Repeated task \(index)\n\nA paragraph with **emphasis**, `inline code`, [[Ideas]], and a [safe link](https://gistpad.dev).\n"
        }.joined()
        #expect(stress.utf16.count > 100_000)
        let stressDocument = PreviewDocument(text: stress, id: "stress", generation: 0)
        _ = try await webView.callAsyncJavaScript(
            "window.gistpadPreview.render(payload);",
            arguments: ["payload": stressDocument.arguments], in: nil, contentWorld: .page
        )
        try await waitFor("100K document") {
            receiver.bodies.contains { $0["type"] as? String == "rendered" && $0["documentID"] as? String == "stress" }
        }
        let headingCount = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('h2').length;",
            arguments: [:], in: nil, contentWorld: .page
        ) as? Int
        #expect(headingCount == 500)
    }

    private func waitFor(_ description: String, condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PreviewFailure.renderer("Timed out waiting for \(description).")
    }
}

@MainActor
private final class MessageReceiver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var bodies: [[String: Any]] = []
    var origins: [String] = []
    var navigationErrors: [String] = []

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationErrors.append(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationErrors.append(error.localizedDescription)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { bodies.append(body) }
        origins.append("\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host)")
    }
}
#endif
