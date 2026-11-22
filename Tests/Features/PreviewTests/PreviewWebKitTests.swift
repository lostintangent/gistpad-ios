#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import Preview

@Suite("Offline WebKit renderer", .serialized)
struct PreviewWebKitTests {
    @Test("The bundled page renders offline, keeps read-only tasks inert and addresses duplicate tasks")
    func offlineRendering() async throws {
        let markdown = try PreviewFixtures.allSyntax
            .replacingOccurrences(of: "![Remote image](https://example.com/gistpad-fixture.png)", with: "")
        let readOnly = PreviewFile(text: markdown, id: "web-kit-fixture", generation: 1, allowsTaskEdits: false)
        let editable = PreviewFile(text: markdown, id: "web-kit-fixture", generation: 1, allowsTaskEdits: true)
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
        controller.view = UIView(frame: webView.frame)
        controller.view.addSubview(webView)
        let window = testWindow(frame: webView.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "gistpadPreview")
            webView.stopLoading()
            window.isHidden = true
            window.rootViewController = nil
        }
        func evaluate(_ script: String) async throws -> Any? {
            try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }
        func render(_ file: PreviewFile) async throws {
            receiver.bodies.removeAll()
            _ = try await webView.callAsyncJavaScript(
                "window.gistpadPreview.render(payload);",
                arguments: ["payload": file.arguments], in: nil, contentWorld: .page
            )
            try await waitFor("rendered message") { receiver.bodies.contains { $0["type"] as? String == "rendered" } }
        }

        _ = try #require(webView.load(URLRequest(url: URL(string: "gistpad-preview://bundle/index.html")!)))
        do {
            try await waitFor("ready message") { receiver.bodies.contains { $0["type"] as? String == "ready" } }
        } catch {
            let state = try await evaluate(
                "return {url:location.href,state:document.readyState,renderer:typeof window.gistpadPreview};")
            let diagnostics = receiver.bodies.filter { $0["type"] as? String == "diagnostic" }
            throw PreviewError("Ready timeout. Page: \(String(describing: state)). Diagnostics: \(diagnostics). Navigation: \(receiver.navigationErrors)")
        }
        #expect(receiver.origins.allSatisfy { $0 == "gistpad-preview://bundle" })

        try await render(readOnly)
        let inert = try await evaluate(
            """
            const boxes = [...document.querySelectorAll('input[type=checkbox]')];
            boxes[1].click();
            return boxes.length === 7 && boxes.every(box =>
                box.disabled && box.getAttribute('aria-label').startsWith('Read-only task: '));
            """) as? Bool
        #expect(inert == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!receiver.bodies.contains { $0["type"] as? String == "taskToggle" })

        try await render(editable)
        let enabled = try await evaluate(
            "return document.querySelectorAll('input[type=checkbox]:not(:disabled)').length;") as? Int
        #expect(enabled == 7)
        _ = try await evaluate("document.querySelectorAll('input[type=checkbox]')[1].click();")
        try await waitFor("task toggle") { receiver.bodies.contains { $0["type"] as? String == "taskToggle" } }
        let toggle = try #require(receiver.bodies.last { $0["type"] as? String == "taskToggle" })
        guard case .event(.taskToggle(let range, _, let replacement, _)) = try PreviewBridge.decode(toggle, file: editable) else {
            Issue.record("Expected a validated source edit")
            return
        }
        #expect(range == (markdown as NSString).range(of: "[x]"))
        #expect(replacement == "[ ]")

        var diagramRendered = false
        for _ in 0..<200 {
            diagramRendered = try await evaluate("return document.querySelector('svg[id^=\"mermaid-\"]') !== null;") as? Bool == true
            if diagramRendered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(diagramRendered)

        _ = try await evaluate("document.querySelector('button.wikilink').click();")
        try await waitFor("wikilink message") { receiver.bodies.contains { $0["kind"] as? String == "wikilink" } }
        let wikilink = try #require(receiver.bodies.last { $0["kind"] as? String == "wikilink" })
        #expect(try PreviewBridge.decode(wikilink, file: editable) == .event(.openWikilink("Ideas")))
        #expect(!receiver.bodies.contains { $0["type"] as? String == "failure" })
    }

    @Test("The reading position survives native width and inset changes", arguments: [false, true])
    func readingCharacterAfterResize(animationsDisabled: Bool) async throws {
        let paragraph = "Keep the useful things close and give each thought enough room to breathe. "
            + "A walk can change the shape of a question before an answer arrives. "
            + "Bring the notebook, notice the small details, and leave a little space for the next person to think. "
        let markdown = "# A long reading note\n\n" + (1...18).map { section in
            "## Section \(section)\n\n"
                + Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        var events: [PreviewEvent] = []
        let controller = UIHostingController(
            rootView: MarkdownPreviewView(markdown: markdown, fileID: "reading-resize", generation: 0) {
                events.append($0)
            })
        let container = UIViewController()
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        let width = controller.view.widthAnchor.constraint(equalToConstant: 840)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            width, controller.view.heightAnchor.constraint(equalToConstant: 500)
        ])
        controller.didMove(toParent: container)
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 951, height: 669))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitFor("long native reading document") {
            (findWebView(in: controller.view)?.scrollView.contentSize.height ?? 0) > 4_000
        }
        let webView = try #require(findWebView(in: controller.view))
        // Let the preview's own initial scroll to the top land first.
        try await settle(webView)
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: 2_500), animated: false)
        _ = try await webView.callAsyncJavaScript(
            """
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            if (scrollY < 2000) throw Error('The native long note is not scrolled');
            // The page's viewport starts below the bars WebKit knows obscure it.
            const x = document.querySelector('article').getBoundingClientRect().left + 8;
            const position = document.caretPositionFromPoint?.(x, 1);
            const range = position ? document.createRange() : document.caretRangeFromPoint(x, 1);
            if (position) range.setStart(position.offsetNode, position.offset);
            if (range.startContainer.nodeType !== Node.TEXT_NODE) throw Error('No native reading character');
            const offset = Math.min(range.startOffset, range.startContainer.textContent.length - 1);
            range.setStart(range.startContainer, offset);
            range.setEnd(range.startContainer, offset + 1);
            window.readingCharacter = range;
            window.readingCharacterTop = range.getBoundingClientRect().top;
            """,
            arguments: [:], in: nil, contentWorld: .page)
        var displacements: [Double] = []
        for _ in 0..<3 {
            for destination: CGFloat in [520, 840] {
                var completed = false
                UIView.animate(withDuration: animationsDisabled ? 0 : 0.35) {
                    width.constant = destination
                    container.view.layoutIfNeeded()
                } completion: { _ in completed = true }
                try await waitFor("native reading width change") { completed }
                let displacement = try #require(try await webView.callAsyncJavaScript(
                    """
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    return window.readingCharacter.getBoundingClientRect().top - window.readingCharacterTop;
                    """,
                    arguments: [:], in: nil, contentWorld: .page) as? Double)
                displacements.append(displacement)
                #expect(abs(displacement) <= 1)
            }
        }
        Attachment.record(
            displacements.map { String(format: "%.3f", $0) }.joined(separator: ","),
            named: "native-reading-character-displacements.txt")

        let originalInset = webView.scrollView.adjustedContentInset.top
        let originalReadingOffset = webView.scrollView.contentOffset.y + originalInset
        for _ in 0..<3 {
            for top: CGFloat in [78, 0] {
                // Bars reach the preview as UIKit safe area, which the page must count exactly once.
                controller.additionalSafeAreaInsets.top = top
                try await waitFor("the changed native reading inset") {
                    abs(webView.scrollView.adjustedContentInset.top - originalInset - top) <= 1
                }
                try await settle(webView)
                #expect(findWebView(in: controller.view) === webView)
                let readingOffset = webView.scrollView.contentOffset.y + webView.scrollView.adjustedContentInset.top
                #expect(abs(readingOffset - originalReadingOffset) <= 1)
                let pageHeight = try #require(try await webView.callAsyncJavaScript(
                    "return innerHeight;", arguments: [:], in: nil, contentWorld: .page) as? Double)
                let inset = webView.scrollView.adjustedContentInset
                #expect(abs(pageHeight - (webView.bounds.height - inset.top - inset.bottom)) <= 1)
            }
        }
        #expect(!events.contains {
            if case .failure = $0 { return true }
            return false
        })
    }

    @Test("A pushed page paints its first frame below the bar", arguments: [false, true])
    func firstFrameBelowTheBar(animated: Bool) async throws {
        let markdown = "# Below the bar\n\n" + Array(
            repeating: "A paragraph long enough that the page runs well past one screen.", count: 80
        ).joined(separator: "\n\n")
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { tearDown(window) }
        let preview = UIHostingController(
            rootView: MarkdownPreviewView(markdown: markdown, fileID: "first-frame", generation: 0) { _ in })
        preview.title = "Below the bar"
        navigation.pushViewController(preview, animated: animated)

        // A rendered page is taller than the screen, so every frame from then on shows text.
        var frames: [String] = []
        var misplaced = 0
        let sampler = FrameSampler {
            guard let scrollView = findWebView(in: preview.view)?.scrollView,
                  scrollView.contentSize.height > 2_000 else { return }
            let gap = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            if abs(gap) > 0.5 || scrollView.adjustedContentInset.top < 1 { misplaced += 1 }
            frames.append(String(format: "%.1f/%.1f", scrollView.contentOffset.y, scrollView.adjustedContentInset.top))
        }
        defer { sampler.stop() }
        try await waitFor("the page to show for a moment") { frames.count >= 45 }
        Attachment.record(frames.joined(separator: "\n"), named: "first-frames-offset-inset.txt")
        #expect(misplaced == 0, "\(misplaced) of \(frames.count) frames showed text out of place")
    }

    @Test("A contents link lands its heading just below the bar", arguments: [
        CGSize(width: 402, height: 874), CGSize(width: 951, height: 669),
    ])
    func contentsLinkLandsBelowTheBar(size: CGSize) async throws {
        let paragraph = "A paragraph long enough to fill a few lines of the reading column, so every section is tall."
        let markdown = "# Contents\n\n```toc\n```\n\n" + (1...20).map {
            "## Section \($0)\n\n" + Array(repeating: paragraph, count: 4).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = testWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { tearDown(window) }
        let preview = UIHostingController(
            rootView: MarkdownPreviewView(markdown: markdown, fileID: "contents", generation: 0) { _ in })
        preview.title = "Contents"
        navigation.pushViewController(preview, animated: false)
        try await waitFor("the long page") {
            (findWebView(in: preview.view)?.scrollView.contentSize.height ?? 0) > 3_000
        }
        let webView = try #require(findWebView(in: preview.view))
        let scrollView = webView.scrollView
        try await settle(webView)
        _ = try await webView.callAsyncJavaScript(
            "document.querySelector('.markdown-toc a[href=\"#section-12\"]').click();",
            arguments: [:], in: nil, contentWorld: .page)
        try await waitFor("the jump") { scrollView.contentOffset.y > 1_000 }
        try await settle(webView)
        let heading = try #require(try await webView.callAsyncJavaScript(
            "return document.getElementById('section-12').getBoundingClientRect().top + scrollY;",
            arguments: [:], in: nil, contentWorld: .page) as? Double)
        // Headings keep a 16-point scroll margin, so this holds only when the bar is counted exactly once.
        let gap = heading - scrollView.contentOffset.y - scrollView.adjustedContentInset.top
        #expect(abs(gap - 16) <= 1, "The heading landed \(gap) points below the bar")
    }

    @Test("A terminated web process renders the same document again")
    func aTerminatedWebProcessRendersAgain() async throws {
        let (webView, window) = try await hostedPreview(markdown: "# Still here\n\nKeep this paragraph.")
        defer { tearDown(window) }
        #expect(try await heading(in: webView) == "Still here")
        try killWebContent(of: webView)
        try await waitFor("the preview to render again after the web process died") {
            (try? await heading(in: webView)) == "Still here"
        }
    }

    private func hostedPreview(markdown: String) async throws -> (WKWebView, UIWindow) {
        let controller = UIHostingController(
            rootView: MarkdownPreviewView(markdown: markdown, fileID: "blank-probe", generation: 1) { _ in }
        )
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await waitFor("hosted preview to render") {
            guard let webView = findWebView(in: controller.view) else { return false }
            return (try? await heading(in: webView)) == "Still here"
        }
        return (try #require(findWebView(in: controller.view)), window)
    }

    private func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func heading(in webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(
            "return document.querySelector('h1')?.textContent ?? null;",
            arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private func killWebContent(of webView: WKWebView) throws {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector), let method = webView.method(for: selector) else {
            throw PreviewError("WKWebView does not expose a web process identifier.")
        }
        typealias Identifier = @convention(c) (AnyObject, Selector) -> Int32
        let pid = unsafeBitCast(method, to: Identifier.self)(webView, selector)
        guard pid > 1 else { throw PreviewError("The preview has no web process.") }
        #expect(kill(pid, SIGKILL) == 0)
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func settle(_ webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(
            "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));",
            arguments: [:], in: nil, contentWorld: .page)
    }

    private func testWindow(frame: CGRect) -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        // Swift package runners can host UIKit without an application scene.
        return UIWindow(frame: frame)
    }

    private func waitFor(_ description: String, condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PreviewError("Timed out waiting for \(description).")
    }
}

/// Runs `sample` once per display frame until stopped.
private final class FrameSampler: NSObject {
    private let sample: @MainActor () -> Void
    private var link: CADisplayLink?

    init(_ sample: @escaping @MainActor () -> Void) {
        self.sample = sample
        super.init()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick() { sample() }

    func stop() { link?.invalidate() }
}

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
