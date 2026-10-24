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

        try await verifyReadingPolish(in: webView, receiver: receiver)

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

    private func verifyReadingPolish(in webView: WKWebView, receiver: MessageReceiver) async throws {
        let document = PreviewDocument(text: try PreviewFixtures.readingPolish, id: "reading-polish", generation: 0)
        _ = try await webView.callAsyncJavaScript(
            "window.gistpadPreview.render(payload);",
            arguments: ["payload": document.arguments], in: nil, contentWorld: .page
        )
        try await waitFor("focused reading fixture") {
            receiver.bodies.contains { $0["type"] as? String == "rendered" && $0["documentID"] as? String == "reading-polish" }
        }
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for contrast: UIAccessibilityContrast in [.normal, .high] {
                for size: UIContentSizeCategory in [.large, .accessibilityExtraLarge] {
                    let traits = UITraitCollection {
                        $0.userInterfaceStyle = style
                        $0.accessibilityContrast = contrast
                        $0.preferredContentSizeCategory = size
                    }
                    let appearance = PreviewAppearance(traits: traits)
                    _ = try await webView.callAsyncJavaScript(
                        "window.gistpadPreview.setAppearance(payload);",
                        arguments: ["payload": appearance.arguments], in: nil, contentWorld: .page
                    )
                    var themed = false
                    for _ in 0..<200 {
                        themed = try await webView.callAsyncJavaScript(
                            """
                            const diagrams = document.querySelectorAll('.diagram-scroll');
                            if (diagrams.length !== 2 || !diagrams[1].querySelector('svg')) return false;
                            const rect = diagrams[0].querySelector('.node rect');
                            if (!rect) return false;
                            const parse = color => color.match(/[\\d.]+/g).map(Number);
                            const styles = getComputedStyle(document.documentElement);
                            const surface = parse(styles.getPropertyValue('--gp-surface')).slice(0, 3);
                            const secondary = parse(styles.getPropertyValue('--gp-text-secondary'));
                            const stroke = secondary.slice(0, 3).map((value, index) =>
                                Math.round(value * (secondary[3] ?? 1) + surface[index] * (1 - (secondary[3] ?? 1))));
                            return parse(getComputedStyle(rect).fill).slice(0, 3).join() === surface.join() &&
                                parse(getComputedStyle(rect).stroke).slice(0, 3).join() === stroke.join();
                            """,
                            arguments: [:], in: nil, contentWorld: .page
                        ) as? Bool == true
                        if themed { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    #expect(themed)
                    let checks = try await webView.callAsyncJavaScript(
                        """
                        const styles = getComputedStyle(document.documentElement);
                        const current = getComputedStyle(document.querySelector('.calculation-current'));
                        const previous = getComputedStyle(document.querySelector('.calculation-previous'));
                        const authored = getComputedStyle(document.querySelectorAll('.diagram-scroll')[1].querySelector('.attention rect'));
                        const summary = document.querySelector('summary');
                        const summaryStyle = getComputedStyle(summary);
                        const parse = color => color.match(/[\\d.]+/g).slice(0, 3).map(Number);
                        const luminance = rgb => rgb.map(value => {
                            value /= 255;
                            return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
                        }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
                        const ratio = (first, second) => {
                            const left = luminance(parse(first)), right = luminance(parse(second));
                            return (Math.max(left, right) + 0.05) / (Math.min(left, right) + 0.05);
                        };
                        const node = getComputedStyle(document.querySelector('.diagram-scroll .node rect'));
                        const arrow = getComputedStyle(document.querySelector('.diagram-scroll .arrowMarkerPath'));
                        const edge = getComputedStyle(document.querySelector('.diagram-scroll .flowchart-link'));
                        const resolveColor = value => {
                            const probe = document.createElement('span');
                            probe.style.color = value;
                            document.body.append(probe);
                            const resolved = getComputedStyle(probe).color;
                            probe.remove();
                            return resolved;
                        };
                        return [
                            [...document.querySelectorAll('.calculation-result')].map(node => node.textContent).join('|') === '$15.00|$15.00|$17.00',
                            document.querySelector('.calculation-current').getAttribute('aria-label') === 'Current result: $15.00',
                            document.querySelector('.calculation-previous').getAttribute('aria-label') === 'Previous result: $15.00',
                            current.fontWeight === '600' && previous.fontWeight === '400' && current.color === styles.color,
                            current.borderRadius === '6px' && current.padding === '2px 4px' && current.webkitUserSelect === 'none',
                            [...document.querySelectorAll('td, th')].every(cell => {
                                const style = getComputedStyle(cell);
                                return style.borderLeftWidth === '0px' && style.borderRightWidth === '0px' &&
                                    style.borderTopWidth === '0px' && style.borderBottomWidth === '0px' &&
                                    style.backgroundColor === 'rgba(0, 0, 0, 0)' && style.fontSize === styles.fontSize;
                            }),
                            [...document.querySelectorAll('table th')].slice(0, 3).map(cell => getComputedStyle(cell).textAlign).join('|') === 'left|center|right',
                            [...document.querySelectorAll('.table-scroll')].some(table => table.scrollWidth > table.clientWidth + 100),
                            [...document.querySelectorAll('table')[1].querySelectorAll('th')].every(cell => {
                                const style = getComputedStyle(cell);
                                return cell.getBoundingClientRect().height <= parseFloat(style.lineHeight) +
                                    parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) + 2;
                            }),
                            summary.getBoundingClientRect().height >= 44 && summaryStyle.fontWeight === '600' && summaryStyle.columnGap === '8px',
                            ratio(node.stroke, node.fill) >= 3 && ratio(node.stroke, styles.backgroundColor) >= 3,
                            ratio(arrow.fill, styles.backgroundColor) >= 3 && ratio(edge.stroke, styles.backgroundColor) >= 3,
                            authored.fill === 'rgb(255, 240, 204)' && authored.stroke === 'rgb(118, 88, 0)',
                            current.backgroundColor === resolveColor(styles.getPropertyValue('--gp-selected-surface')) &&
                                previous.backgroundColor === resolveColor(styles.getPropertyValue('--gp-surface')),
                            document.documentElement.scrollWidth <= window.innerWidth
                        ];
                        """,
                        arguments: [:], in: nil, contentWorld: .page
                    ) as? [Bool]
                    let results = try #require(checks)
                    for (index, passed) in results.enumerated() {
                        #expect(passed, "Reading check \(index), \(style.rawValue)/\(contrast.rawValue)/\(size.rawValue)")
                    }
                }
            }
        }
        let disclosureWorks = try await webView.callAsyncJavaScript(
            """
            const details = document.querySelector('details');
            const summary = details.querySelector('summary');
            summary.focus();
            summary.click();
            const expanded = details.open && document.activeElement === summary;
            summary.click();
            return expanded && !details.open;
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        #expect(disclosureWorks == true)
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
