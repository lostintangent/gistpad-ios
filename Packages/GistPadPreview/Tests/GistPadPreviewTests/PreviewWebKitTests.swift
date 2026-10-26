#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
import GistPadAppearance
import GistPadComments
@testable import GistPadPreview

@MainActor
@Suite("Offline WebKit renderer", .serialized)
struct PreviewWebKitTests {
    @Test("Scrolled reading keeps its distance from a changing native viewport")
    func scrolledViewportInsets() async throws {
        let markdown = "# A reading note\n\n"
            + String(repeating: "A paragraph with enough room to read and scroll.\n\n", count: 100)
        var events: [PreviewEvent] = []
        func preview(top: CGFloat) -> some View {
            MarkdownPreviewView(document: markdown, documentID: "inset-reading", generation: 0) {
                events.append($0)
            }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
        }
        let controller = UIHostingController(rootView: preview(top: 0))
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 951, height: 669))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitFor("native inset reading document") {
            events.contains {
                if case .rendered(documentID: "inset-reading", generation: 0) = $0 { return true }
                return false
            }
        }
        let webView = try #require(findWebView(in: controller.view))
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: 1_000), animated: false)
        _ = try await viewportGeometry(in: webView, selector: "h1")
        let originalInset = webView.scrollView.adjustedContentInset.top
        let originalReadingOffset = webView.scrollView.contentOffset.y + originalInset
        for _ in 0..<3 {
            for top: CGFloat in [78, 0] {
                controller.rootView = preview(top: top)
                try await waitFor("the changed native reading inset") {
                    abs(webView.scrollView.adjustedContentInset.top - originalInset - top) <= 1
                }
                _ = try await viewportGeometry(in: webView, selector: "h1")
                #expect(findWebView(in: controller.view) === webView)
                let readingOffset = webView.scrollView.contentOffset.y + webView.scrollView.adjustedContentInset.top
                #expect(abs(readingOffset - originalReadingOffset) <= 1)
            }
        }
    }

    @Test("The same reading character survives native width changes", arguments: [false, true])
    func readingCharacterAfterResize(animationsDisabled: Bool) async throws {
        let paragraph = "Keep the useful things close and give each thought enough room to breathe. "
            + "A walk can change the shape of a question before an answer arrives. "
            + "Bring the notebook, notice the small details, and leave a little space for the next person to think. "
        let markdown = "# A long reading note\n\n" + (1...18).map { section in
            "## Section \(section)\n\n"
                + Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        var events: [PreviewEvent] = []
        let preview = MarkdownPreviewView(document: markdown, documentID: "reading-resize", generation: 0) {
            events.append($0)
        }
        let controller = UIHostingController(rootView: preview)
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
            events.contains {
                if case .rendered(documentID: "reading-resize", generation: 0) = $0 { return true }
                return false
            }
        }
        let webView = try #require(findWebView(in: controller.view))
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: 2_500), animated: false)
        _ = try await webView.callAsyncJavaScript(
            """
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            if (scrollY < 2000) throw Error('The native long note is not scrolled');
            const top = parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop);
            const x = document.querySelector('article').getBoundingClientRect().left + 8;
            const position = document.caretPositionFromPoint?.(x, top + 1);
            const range = position ? document.createRange() : document.caretRangeFromPoint(x, top + 1);
            if (position) range.setStart(position.offsetNode, position.offset);
            if (range.startContainer.nodeType !== Node.TEXT_NODE) throw Error('No native reading character');
            const offset = Math.min(range.startOffset, range.startContainer.textContent.length - 1);
            range.setStart(range.startContainer, offset);
            range.setEnd(range.startContainer, offset + 1);
            window.readingCharacter = range;
            window.readingCharacterTop = range.getBoundingClientRect().top - top;
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
                    const top = parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop);
                    return window.readingCharacter.getBoundingClientRect().top - top - window.readingCharacterTop;
                    """,
                    arguments: [:], in: nil, contentWorld: .page) as? Double)
                displacements.append(displacement)
                #expect(abs(displacement) <= 1)
            }
        }
        Attachment.record(
            displacements.map { String(format: "%.3f", $0) }.joined(separator: ","),
            named: "native-reading-character-displacements.txt")
        #expect(!events.contains {
            if case .failure = $0 { return true }
            return false
        })
    }

    @Test("The native preview keeps tasks read-only while scrolling under native bars")
    func nativeReadOnlyHost() async throws {
        var events: [PreviewEvent] = []
        let document = "# A calm beginning\n\n[Jump to the last section](#destination)\n\n"
            + String(repeating: "A paragraph with enough room to read and scroll.\n\n", count: 30)
            + "## Destination\n\n- [ ] Read-only task\n\n"
            + String(repeating: "Space after the destination keeps the anchor reachable.\n\n", count: 10)
        let preview = MarkdownPreviewView(
            document: document, documentID: "read-only", generation: 0,
            allowsTaskEdits: false
        ) { events.append($0) }
        let controller = UIHostingController(rootView: preview.environment(\.personalAccent, PersonalAccent()))
        let container = UIViewController()
        container.title = "Reading"
        container.toolbarItems = [UIBarButtonItem(systemItem: .action)]
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        controller.didMove(toParent: container)
        let navigation = UINavigationController(rootViewController: container)
        navigation.setToolbarHidden(false, animated: false)
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitFor("native read-only preview") {
            events.contains {
                if case .rendered(documentID: "read-only", generation: 0) = $0 { return true }
                return false
            }
        }
        let webView = try #require(findWebView(in: controller.view))
        try await waitFor("native bar insets") {
            webView.scrollView.adjustedContentInset.top > 0 &&
                webView.scrollView.adjustedContentInset.bottom > 0
        }
        #expect(webView.scrollView.bounces)
        #expect(webView.scrollView.alwaysBounceVertical)
        #expect(webView.scrollView.contentInsetAdjustmentBehavior == .automatic)
        #expect(webView.scrollView.topEdgeEffect.style == .soft)
        #expect(webView.scrollView.bottomEdgeEffect.style == .soft)
        #expect(!webView.isOpaque)
        #expect(webView.backgroundColor?.cgColor.alpha == 0)
        #expect(webView.scrollView.backgroundColor?.cgColor.alpha == 0)
        #expect(webView.underPageBackgroundColor.cgColor.alpha == 0)
        let webFrame = webView.convert(webView.bounds, to: window)
        let safeFrame = container.view.convert(container.view.safeAreaLayoutGuide.layoutFrame, to: window)
        #expect(webFrame.minY < safeFrame.minY)
        #expect(webFrame.maxY > safeFrame.maxY)
        #expect(safeFrame.height > 0)
        #expect(webFrame.minY + webView.scrollView.adjustedContentInset.top >= safeFrame.minY - 1)
        #expect(webFrame.maxY - webView.scrollView.adjustedContentInset.bottom <= safeFrame.maxY + 1)
        let resting = try await viewportGeometry(in: webView, selector: "h1")
        Attachment.record(String(describing: resting), named: "native-preview-resting-geometry.txt")
        #expect(abs(webView.scrollView.contentOffset.y + webView.scrollView.adjustedContentInset.top) <= 1)
        #expect(try #require(resting["nativeElementTop"]) >= webView.scrollView.adjustedContentInset.top + 23)
        #expect(resting["scrollPaddingTop"] == Double(webView.scrollView.adjustedContentInset.top))
        #expect(resting["scrollPaddingBottom"] == Double(webView.scrollView.adjustedContentInset.bottom))
        _ = try await webView.callAsyncJavaScript(
            "document.querySelector('a[href=\"#destination\"]').click();",
            arguments: [:], in: nil, contentWorld: .page
        )
        let anchor = try await viewportGeometry(in: webView, selector: "#destination")
        Attachment.record(String(describing: anchor), named: "native-preview-anchor-geometry.txt")
        #expect(anchor["focused"] == 1)
        #expect(try #require(anchor["scrollY"]) > 0)
        let anchorTop = try #require(anchor["nativeElementTop"])
        let visibleTop = webView.scrollView.adjustedContentInset.top
        #expect(anchorTop >= visibleTop + 15 && anchorTop <= visibleTop + 17)
        let readOnly = try await webView.callAsyncJavaScript(
            """
            const input = document.querySelector('input[type=checkbox]');
            const disabled = input.disabled && input.getAttribute('aria-label') === 'Read-only task: Read-only task';
            input.scrollIntoView({block: 'center'});
            input.click();
            return disabled;
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        #expect(readOnly == true)
        let task = try await viewportGeometry(in: webView, selector: "input[type=checkbox]")
        Attachment.record(String(describing: task), named: "native-preview-task-geometry.txt")
        #expect(try #require(task["nativeElementTop"]) >= visibleTop)
        #expect(try #require(task["nativeElementBottom"]) <= webView.bounds.height - webView.scrollView.adjustedContentInset.bottom)
        let readingOffset = webView.scrollView.contentOffset
        controller.rootView = MarkdownPreviewView(
            document: document + "\n", documentID: "read-only", generation: 1,
            allowsTaskEdits: false
        ) { events.append($0) }
            .environment(\.personalAccent, PersonalAccent())
        try await waitFor("same-document update") {
            events.contains {
                if case .rendered(documentID: "read-only", generation: 1) = $0 { return true }
                return false
            }
        }
        let updated = try await viewportGeometry(in: webView, selector: "input[type=checkbox]")
        Attachment.record(String(describing: updated), named: "native-preview-updated-geometry.txt")
        #expect(findWebView(in: controller.view) === webView)
        #expect(abs(webView.scrollView.contentOffset.y - readingOffset.y) <= 1)
        _ = try await webView.callAsyncJavaScript(
            """
            window.accentParagraph = document.querySelector('article > p');
            const range = document.createRange();
            range.selectNodeContents(window.accentParagraph);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            window.accentSelection = selection.toString();
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        controller.rootView = MarkdownPreviewView(
            document: document + "\n", documentID: "read-only", generation: 1,
            allowsTaskEdits: false
        ) { events.append($0) }
            .environment(\.personalAccent, PersonalAccent(savedHex: "#FACC15"))
        let personalTraits = webView.traitCollection.modifyingTraits {
            $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: "#FACC15")
        }
        let expectedAccent = PersonalAccent(savedHex: "#FACC15").roles(traits: personalTraits).text.hex
        var accentApplied = false
        for _ in 0..<100 {
            accentApplied = try await webView.callAsyncJavaScript(
                """
                return getComputedStyle(document.documentElement).getPropertyValue('--gp-accent-text').trim() === expected &&
                    document.querySelector('article > p') === window.accentParagraph &&
                    window.getSelection().toString() === window.accentSelection;
                """,
                arguments: ["expected": expectedAccent], in: nil, contentWorld: .page
            ) as? Bool == true
            if accentApplied { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(accentApplied)
        #expect(abs(webView.scrollView.contentOffset.y - readingOffset.y) <= 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!events.contains {
            switch $0 {
            case .taskToggle, .failure: true
            default: false
            }
        })
    }

    @Test("Selected comments reveal and repeat within the actual native viewport")
    func nativeCommentReveal() async throws {
        let markdown = "# A beginning\n\n"
            + String(repeating: "A little room for another thought.\n\n", count: 60)
            + "A final native passage."
        var configuration = CommentHighlightConfiguration(
            quotes: [CommentQuote(commentID: 60, quote: "final native passage")],
            selectedCommentID: 60)
        var events: [PreviewEvent] = []
        var linked: Set<Int64> = []
        func preview(_ comments: CommentHighlightConfiguration) -> some View {
            MarkdownPreviewView(
                document: markdown, documentID: "native-reveal", generation: 0,
                comments: comments, onLinkedCommentIDsChange: { linked = $0 }
            ) { events.append($0) }
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 120) }
                .environment(\.dynamicTypeSize, .accessibility3)
        }
        let controller = UIHostingController(rootView: preview(configuration))
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitFor("matched native comment") { linked == [60] }
        let webView = try #require(findWebView(in: controller.view))
        var lastGeometry: [String: Double] = [:]
        func verifiedPassageIsVisible() async throws -> Bool {
            for _ in 0..<100 {
                let geometry = try await viewportGeometry(in: webView, selector: ".comment-selected")
                lastGeometry = geometry
                if try #require(geometry["nativeElementTop"]) >= Double(webView.scrollView.adjustedContentInset.top),
                   try #require(geometry["nativeElementBottom"]) <=
                    Double(webView.bounds.height - webView.scrollView.adjustedContentInset.bottom) {
                    return true
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        #expect(try await verifiedPassageIsVisible(), "\(lastGeometry)")
        let top = -webView.scrollView.adjustedContentInset.top
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        controller.rootView = preview(configuration)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(webView.scrollView.contentOffset.y - top) < 1)
        configuration.revealRevision += 1
        controller.rootView = preview(configuration)
        #expect(try await verifiedPassageIsVisible(), "\(lastGeometry)")
        #expect(!events.contains { if case .failure = $0 { true } else { false } })
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func viewportGeometry(in webView: WKWebView, selector: String) async throws -> [String: Double] {
        let result = try await webView.callAsyncJavaScript(
            """
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const element = document.querySelector(selector);
            const rect = element.getBoundingClientRect();
            const styles = getComputedStyle(document.documentElement);
            return {
                elementTop: rect.top, elementBottom: rect.bottom,
                focused: document.activeElement === element ? 1 : 0,
                scrollY: window.scrollY, innerHeight: window.innerHeight,
                visualTop: window.visualViewport.offsetTop, visualHeight: window.visualViewport.height,
                scrollPaddingTop: parseFloat(styles.scrollPaddingTop),
                scrollPaddingBottom: parseFloat(styles.scrollPaddingBottom)
            };
            """,
            arguments: ["selector": selector], in: nil, contentWorld: .page
        ) as? [String: Double]
        var geometry = try #require(result)
        geometry["nativeOffsetY"] = webView.scrollView.contentOffset.y
        geometry["nativeTopInset"] = webView.scrollView.adjustedContentInset.top
        geometry["nativeBottomInset"] = webView.scrollView.adjustedContentInset.bottom
        geometry["nativeHeight"] = webView.bounds.height
        geometry["nativeContentHeight"] = webView.scrollView.contentSize.height
        let scrollY = try #require(geometry["scrollY"])
        let elementTop = try #require(geometry["elementTop"])
        let elementBottom = try #require(geometry["elementBottom"])
        geometry["nativeElementTop"] = elementTop + scrollY - webView.scrollView.contentOffset.y
        geometry["nativeElementBottom"] = elementBottom + scrollY - webView.scrollView.contentOffset.y
        return geometry
    }

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
        _ = try #require(webView.load(URLRequest(url: URL(string: "gistpad-preview://bundle/index.html")!)))
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
                        $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: size == .large ? nil : "#FACC15")
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
            const disclosure = outline.closest('details');
            const initiallyCollapsed = !disclosure.open;
            disclosure.querySelector('summary').click();
            return initiallyCollapsed && disclosure.open &&
                getComputedStyle(disclosure.querySelector('summary')).fontFamily.includes('-apple-system') &&
                [...outline.querySelectorAll('a')].every(anchor =>
                    anchor.getBoundingClientRect().height >= 44 &&
                    getComputedStyle(anchor).textDecorationLine === 'none') &&
                document.querySelectorAll('.markdown-alert-title > svg.alert-symbol').length === 5;
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        #expect(readingPresentation == true)
        _ = try await webView.callAsyncJavaScript(
            """
            const paragraph = document.querySelector('article > p');
            const range = document.createRange();
            range.selectNodeContents(paragraph);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            window.previewSelectedText = selection.toString();
            window.previewParagraph = paragraph;
            window.gistpadPreview.setTaskEditingEnabled(false);
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        var readOnly = false
        for _ in 0..<100 {
            readOnly = try await webView.callAsyncJavaScript(
                """
                return [...document.querySelectorAll('input[type=checkbox]')].every(input =>
                    input.disabled && input.getAttribute('aria-label').startsWith('Read-only task: ') &&
                    getComputedStyle(input).opacity === '1' && getComputedStyle(input.closest('li')).opacity === '1') &&
                    document.querySelector('article > p') === window.previewParagraph &&
                    window.getSelection().toString() === window.previewSelectedText;
                """,
                arguments: [:], in: nil, contentWorld: .page
            ) as? Bool == true
            if readOnly { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(readOnly)
        _ = try await webView.callAsyncJavaScript(
            """
            document.querySelectorAll('input[type=checkbox]')[1].click();
            window.getSelection().removeAllRanges();
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(!receiver.bodies.contains { ["taskToggle", "failure"].contains($0["type"] as? String ?? "") })
        _ = try await webView.callAsyncJavaScript(
            "window.gistpadPreview.setTaskEditingEnabled(true);",
            arguments: [:], in: nil, contentWorld: .page
        )
        var editable = false
        for _ in 0..<100 {
            editable = try await webView.callAsyncJavaScript(
                "return !document.querySelectorAll('input[type=checkbox]')[1].disabled;",
                arguments: [:], in: nil, contentWorld: .page
            ) as? Bool == true
            if editable { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(editable)
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
        #expect(webView.scrollView.contentSize.height > webView.scrollView.bounds.height)

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
        try await verifyHeadingWrapping(in: webView, receiver: receiver)

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
                for size: UIContentSizeCategory in [.large, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
                    let traits = UITraitCollection {
                        $0.userInterfaceStyle = style
                        $0.accessibilityContrast = contrast
                        $0.preferredContentSizeCategory = size
                        $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: size == .large ? nil : "#FACC15")
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
                            const theme = JSON.parse(diagrams[0].dataset.nativeTheme);
                            return parse(getComputedStyle(rect).fill).slice(0, 3).join() === surface.join() &&
                                parse(getComputedStyle(rect).stroke).slice(0, 3).join() === theme.stroke.join() &&
                                parse(getComputedStyle(diagrams[0].querySelector('.flowchart-link')).stroke).join() === theme.edge.join();
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
                        const summary = document.querySelector('details:not(.markdown-toc) summary');
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
                        const table = document.querySelectorAll('.table-scroll')[1];
                        const pageOffset = window.scrollX;
                        table.scrollLeft = table.scrollWidth;
                        const scrolledLocally = table.scrollLeft > 100 && window.scrollX === pageOffset;
                        table.scrollLeft = 0;
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
                            scrolledLocally,
                            [...document.querySelectorAll('table')[1].querySelectorAll('th')].every(cell => {
                                const style = getComputedStyle(cell);
                                return cell.getBoundingClientRect().height <= parseFloat(style.lineHeight) +
                                    parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) + 2;
                            }),
                            summary.getBoundingClientRect().height >= 44 && summaryStyle.fontWeight === '600' && summaryStyle.columnGap === '8px',
                            ratio(node.stroke, node.fill) >= 3 && ratio(node.stroke, styles.backgroundColor) >= 3,
                            ratio(arrow.fill, styles.backgroundColor) >= 3 && ratio(edge.stroke, styles.backgroundColor) >= 3,
                            node.rx === '10px' && node.ry === '10px' && node.strokeWidth === '1px',
                            document.querySelectorAll('.diagram-scroll')[1].querySelector('.node polygon') !== null,
                            edge.stroke === resolveColor(styles.getPropertyValue('--gp-accent-text')) &&
                                getComputedStyle(document.querySelector('.text-blue-500')).color === resolveColor(styles.getPropertyValue('--gp-accent-text')),
                            getComputedStyle(document.querySelector('.diagram-scroll .nodeLabel')).color === styles.color,
                            Math.abs(document.querySelector('.markdown-toc').nextElementSibling.getBoundingClientRect().top -
                                document.querySelector('.markdown-toc').getBoundingClientRect().bottom - 3 * parseFloat(styles.fontSize)) < 1,
                            authored.fill === 'rgb(255, 240, 204)' && authored.stroke === 'rgb(118, 88, 0)',
                            current.backgroundColor === resolveColor(styles.getPropertyValue('--gp-selected-surface')) &&
                                previous.backgroundColor === resolveColor(styles.getPropertyValue('--gp-surface')),
                            document.documentElement.scrollWidth <= window.innerWidth,
                            ['h1', 'h2', 'h3'].every((selector, index) => {
                                const heading = getComputedStyle(document.querySelector(selector));
                                return heading.fontFamily.includes('-apple-system') &&
                                    Math.abs(parseFloat(heading.fontSize) -
                                        parseFloat(styles.getPropertyValue(`--gp-title${index + 1}-size`))) < .1;
                            }),
                            ['h1', 'h2'].every(selector => {
                                const heading = getComputedStyle(document.querySelector(selector));
                                return heading.borderBottomWidth === '1px' &&
                                    heading.borderBottomColor === resolveColor(styles.getPropertyValue('--border')) &&
                                    Math.abs(parseFloat(heading.paddingBottom) - parseFloat(styles.fontSize)) < .1;
                            }),
                            Math.abs(parseFloat(getComputedStyle(document.querySelector('article')).lineHeight) -
                                1.75 * parseFloat(styles.fontSize)) < .1,
                            Math.abs(parseFloat(getComputedStyle(document.querySelector('article > p')).marginBottom) -
                                1.25 * parseFloat(styles.fontSize)) < .1,
                            Math.abs(parseFloat(getComputedStyle(document.querySelector('li.task-list-item')).marginBottom) -
                                .5 * parseFloat(styles.fontSize)) < .1,
                            document.querySelector('article > ol').start === 3 &&
                                document.querySelectorAll('article > ol > li, article > ul:not(.contains-task-list) li').length === 4,
                            [...document.querySelectorAll('article > ol > li, article > ul:not(.contains-task-list) li')].every(item => {
                                const marker = getComputedStyle(item, '::marker');
                                const text = getComputedStyle(item);
                                const bullet = item.parentElement.tagName === 'UL';
                                const increased = document.documentElement.dataset.contrast === 'increased';
                                return marker.color === resolveColor(styles.getPropertyValue(bullet ? '--gp-list-bullet' : '--gp-list-number')) &&
                                    (bullet && !increased || ratio(marker.color, styles.backgroundColor) >= (increased ? 7 : 4.5)) &&
                                    text.color === styles.color && marker.fontWeight === text.fontWeight;
                            }),
                            [...document.querySelectorAll('.markdown-toc li, li.task-list-item')].every(item =>
                                getComputedStyle(item, '::marker').color === styles.color),
                            [...document.querySelectorAll('.task-toggle input')].every(input => {
                                const box = getComputedStyle(input);
                                return box.borderTopColor === resolveColor(styles.getPropertyValue('--gp-list-marker')) &&
                                    (!input.checked ||
                                        (box.backgroundColor === resolveColor(styles.getPropertyValue('--gp-list-marker')) &&
                                            ratio(getComputedStyle(input, '::after').borderTopColor, box.backgroundColor) >= 3)) &&
                                    input.closest('.task-toggle').getBoundingClientRect().height >= 44 &&
                                    getComputedStyle(input.closest('li')).color === styles.color;
                            })
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
            const details = document.querySelector('details:not(.markdown-toc)');
            const summary = details.querySelector('summary');
            summary.focus();
            summary.click();
            const expanded = details.open && document.activeElement === summary;
            summary.click();
            return expanded && !details.open && document.querySelectorAll('details:not(.markdown-toc)')[1].open &&
                !document.querySelector('details.markdown-toc').open;
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        #expect(disclosureWorks == true)
    }

    private func verifyHeadingWrapping(in webView: WKWebView, receiver: MessageReceiver) async throws {
        let document = PreviewDocument(text: try PreviewFixtures.headingWrapping, id: "heading-wrapping", generation: 0)
        _ = try await webView.callAsyncJavaScript(
            "window.gistpadPreview.render(payload);",
            arguments: ["payload": document.arguments], in: nil, contentWorld: .page
        )
        try await waitFor("heading wrapping fixture") {
            receiver.bodies.contains { $0["type"] as? String == "rendered" && $0["documentID"] as? String == "heading-wrapping" }
        }
        let originalFrame = webView.frame
        defer { webView.frame = originalFrame }
        for width: CGFloat in [382, 834] {
            webView.frame.size.width = width
            for size: UIContentSizeCategory in [.large, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
                for style: UIUserInterfaceStyle in [.light, .dark] {
                    let traits = UITraitCollection {
                        $0.preferredContentSizeCategory = size
                        $0.userInterfaceStyle = style
                    }
                    let appearance = PreviewAppearance(traits: traits)
                    let checks = try await webView.callAsyncJavaScript(
                        """
                        window.gistpadPreview.setAppearance(payload);
                        for (let attempt = 0; window.innerWidth !== width && attempt < 100; attempt++) {
                            await new Promise(resolve => setTimeout(resolve, 20));
                        }
                        await new Promise(resolve => requestAnimationFrame(resolve));
                        const headings = ['h1', 'h2', 'h3'].map(selector => document.querySelector(selector));
                        const wholeWords = headings.every(heading => {
                            if (heading.textContent !== 'The shape of a notebook') return false;
                            const text = document.createTreeWalker(heading, NodeFilter.SHOW_TEXT).nextNode();
                            if (!text || text.textContent !== heading.textContent) return false;
                            return [...text.textContent.matchAll(/\\S+/g)].every(word => {
                                const range = document.createRange();
                                range.setStart(text, word.index);
                                range.setEnd(text, word.index + word[0].length);
                                return range.getClientRects().length === 1;
                            });
                        });
                        const oversized = document.querySelectorAll('h1')[1];
                        const range = document.createRange();
                        range.selectNodeContents(oversized);
                        return [
                            window.innerWidth === width,
                            wholeWords,
                            headings.every(heading => getComputedStyle(heading).wordBreak === 'normal' &&
                                getComputedStyle(heading).overflowWrap === 'break-word'),
                            range.getClientRects().length > 1,
                            document.documentElement.scrollWidth <= window.innerWidth
                        ];
                        """,
                        arguments: ["payload": appearance.arguments, "width": width], in: nil, contentWorld: .page
                    ) as? [Bool]
                    for (index, passed) in try #require(checks).enumerated() {
                        #expect(passed, "Heading wrapping check \(index), \(width)/\(size.rawValue)/\(style.rawValue)")
                    }
                    if width == 382, style == .dark {
                        Attachment.record(
                            String(describing: appearance.variables),
                            named: "heading-metrics-\(size.rawValue).txt"
                        )
                    }
                }
            }
        }
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
