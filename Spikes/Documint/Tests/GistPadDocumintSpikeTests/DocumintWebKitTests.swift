#if os(iOS)
import GistPadEditor
import GistPadPreview
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import GistPadDocumintSpike

@MainActor
@Suite(.serialized)
struct DocumintWebKitTests {
    @Test("Offline rich input reaches the same native source and draft callback")
    func nativeRoundTrip() async throws {
        let markdown = try DocumintSpikeFixtures.markdown
        let session = DocumentSession(documentID: "native-rich", text: markdown)
        var failures: [String] = []
        var renders: [Double] = []
        var changes: [String] = []
        session.onSourceChange = { text, _ in changes.append(text) }
        let host = UIHostingController(rootView: DocumintSpikeView(
            session: session, onFailure: { failures.append($0) }, onRendered: { renders.append($0) }
        ))
        let window = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait("the first rich frame") { !renders.isEmpty || !failures.isEmpty }
        #expect(failures.isEmpty, "\(failures)")
        #expect(session.text.utf8.elementsEqual(markdown.utf8))
        #expect(changes.isEmpty)
        let webView = try #require(findWebView(in: host.view))
        let metrics = try await webView.callAsyncJavaScript(
            "return window.gistpadDocumint.metrics();", arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Any]
        #expect(metrics?["canvas"] as? Bool == true)
        #expect(metrics?["semanticHeadings"] as? Int == 0)
        #expect(metrics?["spellcheck"] as? Bool == false)
        let images = try await webView.callAsyncJavaScript(
            """
            const results = [];
            for (const name of ['pixel.png', 'pixel.svg']) {
                const response = await fetch('./' + name);
                const row = {name, status: response.status, ok: response.ok};
                try {
                    const image = await createImageBitmap(await response.blob());
                    Object.assign(row, {width: image.width, height: image.height});
                    image.close();
                } catch (error) { row.error = String(error); }
                results.push(row);
            }
            return results;
            """, arguments: [:], in: nil, contentWorld: .page
        ) as? [[String: Any]]
        let png = try #require(images?.first)
        #expect(png["ok"] as? Bool == true)
        #expect(png["width"] as? Int == 240)
        Attachment.record(String(describing: images), named: "native-bundled-image-decode.txt")
        _ = try await webView.callAsyncJavaScript(
            """
            const canvas = document.querySelector('.documint-content-canvas');
            canvas.focus();
            const input = document.querySelector('textarea.documint-input');
            input.focus();
            input.dispatchEvent(new InputEvent('beforeinput', {
                inputType: 'insertText', data: 'Z', bubbles: true, cancelable: true
            }));
            """, arguments: [:], in: nil, contentWorld: .page
        )
        try await wait("the native source transaction") { !changes.isEmpty || !failures.isEmpty }
        #expect(failures.isEmpty, "\(failures)")
        #expect(session.text.contains("Z"))
        #expect(session.generation == 1)
        #expect(changes.count == 1)
        #expect(session.textView.text.utf8.elementsEqual(session.text.utf8))
        let pending = try await webView.callAsyncJavaScript(
            "return window.gistpadDocumint.metrics().pending;", arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        #expect(pending == false)
        Attachment.record(String(describing: metrics), named: "native-rich-metrics.txt")
    }

    @Test("Real notes stay unchanged until iOS WebKit emits a one-character edit")
    func privateNoteRoundTrips() async throws {
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("DocumintSpike/PrivateFixtures", isDirectory: true)
        var rows: [[String: Any]] = []
        for name in ["manga", "daily", "oss"] {
            let source = try String(contentsOf: directory.appendingPathComponent("\(name).md"), encoding: .utf8)
            let session = DocumentSession(documentID: name, text: source)
            var rendered = false
            var failures: [String] = []
            var callbacks = 0
            session.onSourceChange = { _, _ in callbacks += 1 }
            let host = UIHostingController(rootView: DocumintSpikeView(
                session: session, onFailure: { failures.append($0) },
                onRendered: { _ in rendered = true }
            ))
            let window = try show(host)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await wait("the private \(name) frame") { rendered || !failures.isEmpty }
            #expect(failures.isEmpty)
            try await Task.sleep(for: .milliseconds(150))
            let unchanged = source.utf8.elementsEqual(session.text.utf8)
            let idleCallbacks = callbacks
            #expect(unchanged)
            #expect(idleCallbacks == 0)
            let webView = try #require(findWebView(in: host.view))
            _ = try await webView.callAsyncJavaScript(
                """
                document.querySelector('.documint-content-canvas').focus();
                const input = document.querySelector('textarea.documint-input');
                input.focus();
                input.dispatchEvent(new InputEvent('beforeinput', {
                    inputType: 'insertText', data: 'Z', bubbles: true, cancelable: true
                }));
                """, arguments: [:], in: nil, contentWorld: .page
            )
            try await wait("the private \(name) source callback") { callbacks > 0 || !failures.isEmpty }
            #expect(failures.isEmpty)
            #expect(callbacks == 1)
            let afterEdit = session.text
            let diff = changedLineCounts(from: source, to: afterEdit)
            let sourceInsTags = source.components(separatedBy: "<ins>").count - 1
            let editedInsTags = afterEdit.components(separatedBy: "<ins>").count - 1
            #expect(sourceInsTags == editedInsTags)
            let originalFrontMatter = frontMatter(in: source)
            let editedFrontMatter = frontMatter(in: afterEdit)
            let frontMatterIsExact = originalFrontMatter.map { original in
                editedFrontMatter.map { original.utf8.elementsEqual($0.utf8) } ?? false
            } ?? (editedFrontMatter == nil)
            #expect(frontMatterIsExact)
            var pending = true
            for _ in 0..<100 where pending {
                pending = try await webView.callAsyncJavaScript(
                    "return window.gistpadDocumint.metrics().pending;",
                    arguments: [:], in: nil, contentWorld: .page
                ) as? Bool ?? true
                if pending { try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(!pending)
            rows.append([
                "note": name, "sourceBytes": source.utf8.count,
                "idleByteIdentical": unchanged, "idleCallbacks": idleCallbacks,
                "editCallbacks": callbacks, "editedBytes": afterEdit.utf8.count,
                "addedLines": diff.added, "removedLines": diff.removed,
                "sourceInsTags": sourceInsTags, "editedInsTags": editedInsTags,
                "hasFrontMatter": originalFrontMatter != nil,
                "frontMatterByteIdentical": frontMatterIsExact
            ])
            session.textView.undoManager?.undo()
            let undoIsExact = source.utf8.elementsEqual(session.text.utf8)
            #expect(undoIsExact)
            webView.endEditing(true)
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        Attachment.record(String(decoding: data, as: UTF8.self), named: "private-note-roundtrip-counts.json")
    }

    @Test("Cold native hosts compare rich and Preview on the same local Markdown")
    func coldOpen() async throws {
        let source = try DocumintSpikeFixtures.markdown
        var rows: [String] = []
        for run in 1...5 {
            for rich in [false, true] {
                var completed = false
                var failures: [String] = []
                let started = ContinuousClock.now
                let host: UIViewController
                if rich {
                    let session = DocumentSession(documentID: "cold-\(run)", text: source)
                    host = UIHostingController(rootView: DocumintSpikeView(
                        session: session, onFailure: { failures.append($0) },
                        onRendered: { _ in completed = true }
                    ))
                } else {
                    host = UIHostingController(rootView: MarkdownPreviewView(
                        document: source, documentID: "cold-\(run)", generation: 0
                    ) { event in
                        switch event {
                        case .rendered: completed = true
                        case .failure(let error): failures.append(error.localizedDescription)
                        default: break
                        }
                    })
                }
                let window = try show(host)
                try await wait("the cold \(rich ? "rich" : "Preview") frame") {
                    completed || !failures.isEmpty
                }
                let elapsed = started.duration(to: .now)
                #expect(failures.isEmpty, "\(failures)")
                rows.append("\(rich ? "Rich" : "Preview"),\(run),\(elapsed)")
                window.isHidden = true
                window.rootViewController = nil
            }
        }
        Attachment.record("surface,run,host_to_rendered\n" + rows.joined(separator: "\n"),
            named: "cold-open-comparison.csv")
    }

    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "The native WebKit gate requires a connected iOS scene.")
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func changedLineCounts(from source: String, to output: String) -> (added: Int, removed: Int) {
        let before = source.components(separatedBy: "\n")
        let after = output.components(separatedBy: "\n")
        var previous = Array(repeating: 0, count: after.count + 1)
        for line in before {
            var current = Array(repeating: 0, count: after.count + 1)
            for (index, candidate) in after.enumerated() {
                current[index + 1] = line.utf8.elementsEqual(candidate.utf8)
                    ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            previous = current
        }
        let unchanged = previous[after.count]
        return (after.count - unchanged, before.count - unchanged)
    }

    private func frontMatter(in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" })
        else { return nil }
        return lines.prefix(closing + 1).joined(separator: "\n")
    }

    private func wait(_ label: String, until predicate: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !predicate() {
            guard start.duration(to: .now) < .seconds(20) else {
                throw WaitFailure(label: label)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private struct WaitFailure: Error { let label: String }
}
#endif
