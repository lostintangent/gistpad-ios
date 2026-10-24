#if os(iOS)
import Foundation
import Testing
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
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "gistpadPreview")
            webView.stopLoading()
        }
        webView.load(URLRequest(url: URL(string: "gistpad-preview://bundle/index.html")!))
        try await waitFor("ready message") { receiver.bodies.contains { $0["type"] as? String == "ready" } }
        #expect(receiver.origins.allSatisfy { $0 == "gistpad-preview://bundle" })
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
                    let appliedSize = try await webView.callAsyncJavaScript(
                        "return getComputedStyle(document.documentElement).getPropertyValue('--gp-body-size');",
                        arguments: [:], in: nil, contentWorld: .page
                    ) as? String
                    #expect(appliedSize == appearance.variables["--gp-body-size"])
                }
            }
        }
        _ = try await webView.callAsyncJavaScript(
            "window.gistpadPreview.render(payload);",
            arguments: ["payload": document.arguments], in: nil, contentWorld: .page
        )
        try await waitFor("rendered message") { receiver.bodies.contains { $0["type"] as? String == "rendered" } }
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
private final class MessageReceiver: NSObject, WKScriptMessageHandler {
    var bodies: [[String: Any]] = []
    var origins: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { bodies.append(body) }
        origins.append("\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host)")
    }
}
#endif
