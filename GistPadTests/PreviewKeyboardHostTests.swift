import GistPadPreview
import SwiftUI
import Testing
import UIKit
import WebKit

@MainActor
@Suite(.serialized)
struct PreviewKeyboardHostTests {
    @Test("Keyboard avoidance and a native shelf leave a usable preview viewport")
    func keyboardViewport() async throws {
        let input = UITextField()
        input.placeholder = "Synthetic keyboard input"
        let source = "# A reachable page\n\n"
            + String(repeating: "Enough text to scroll beneath the native chrome.\n\n", count: 25)
            + "- [ ] A reachable task\n\n"
            + String(repeating: "Enough text to scroll beneath the native chrome.\n\n", count: 25)
            + "- [ ] Last task\n"
        var rendered = false
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            NavigationStack {
                VStack(spacing: 0) {
                    PreviewKeyboardInput(field: input).frame(height: 44)
                    MarkdownPreviewView(document: source, documentID: "keyboard-preview", generation: 0) { event in
                        if case .rendered = event { rendered = true }
                    }
                }
                .navigationTitle("Reading")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text("Synthetic attachment shelf").frame(maxWidth: .infinity).frame(height: 120)
                }
            }
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            input.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitFor("preview keyboard fixture") { rendered }
        let preview = try #require(findWebView(in: host.view))
        let originalHeight = preview.bounds.height
        #expect(input.becomeFirstResponder())
        try await waitFor("real keyboard") { host.view.keyboardLayoutGuide.layoutFrame.height > 100 }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let insets = preview.scrollView.adjustedContentInset
        let visibleHeight = preview.bounds.height - insets.top - insets.bottom
        Attachment.record(
            "originalHeight: \(originalHeight), bounds: \(preview.bounds), adjustedInsets: \(insets), visibleHeight: \(visibleHeight), keyboard: \(host.view.keyboardLayoutGuide.layoutFrame)",
            named: "preview-keyboard-viewport.txt"
        )
        #expect(visibleHeight >= 100)
        #expect(abs(insets.bottom - 120) <= 1)
        let scrollPadding = try await preview.callAsyncJavaScript(
            "return parseFloat(getComputedStyle(document.documentElement).scrollPaddingBottom);",
            arguments: [:], in: nil, contentWorld: .page
        ) as? Double
        #expect(scrollPadding == Double(insets.bottom))
        _ = try await preview.callAsyncJavaScript(
            "document.querySelector('input[type=checkbox]').scrollIntoView({block: 'center'});",
            arguments: [:], in: nil, contentWorld: .page
        )
        let geometry = try await preview.callAsyncJavaScript(
            """
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const rect = document.querySelector('input[type=checkbox]').getBoundingClientRect();
            return {top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY};
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Double]
        let top = try #require(geometry?["top"]) - preview.scrollView.contentOffset.y
        let bottom = try #require(geometry?["bottom"]) - preview.scrollView.contentOffset.y
        #expect(top >= insets.top - 1)
        #expect(bottom <= preview.bounds.height - insets.bottom + 1)

        preview.scrollView.setContentOffset(
            CGPoint(x: 0, y: preview.scrollView.contentSize.height - preview.bounds.height + insets.bottom),
            animated: false
        )
        let lastBottom = try await preview.callAsyncJavaScript(
            """
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const inputs = document.querySelectorAll('input[type=checkbox]');
            return inputs[inputs.length - 1].getBoundingClientRect().bottom + window.scrollY;
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? Double
        #expect(try #require(lastBottom) - preview.scrollView.contentOffset.y <= visibleHeight + 1)

        input.resignFirstResponder()
        try await waitFor("keyboard dismissal") { host.view.keyboardLayoutGuide.layoutFrame.height < 100 }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        #expect(abs(preview.bounds.height - originalHeight) <= 1)
        #expect(preview.bounds.height - preview.scrollView.adjustedContentInset.top
            - preview.scrollView.adjustedContentInset.bottom >= 100)
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func waitFor(_ name: String, condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PreviewKeyboardFailure.timedOut(name)
    }
}

private enum PreviewKeyboardFailure: Error {
    case timedOut(String)
}

private struct PreviewKeyboardInput: UIViewRepresentable {
    let field: UITextField
    func makeUIView(context: Context) -> UITextField { field }
    func updateUIView(_ view: UITextField, context: Context) {}
}
