import GistPadAppearance
import GistPadEditor
import GistPadInterface
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct PreviewIntegrationTests {
    @Test("Changing a profile accent preserves the real source editor's attributed content and viewport")
    func profileAccentPreservesSource() async throws {
        let source = "# A retained thought\n\n" + String(repeating: "A paragraph with **emphasis** and `code`.\n\n", count: 50)
        let session = DocumentSession(documentID: "accent-source", text: source)
        var sourceChanges = 0
        session.onSourceChange = { _, _ in sourceChanges += 1 }
        let window = try testWindow()
        let host = UIHostingController(
            rootView: sourceFixture(session: session, accent: "#FACC15")
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let editor = session.textView
        try await waitFor("source profile trait") {
            editor.traitCollection[PersonalAccentTrait.self].savedHex == "#FACC15"
        }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        editor.selectedRange = NSRange(location: source.utf16.count / 2, length: 8)
        editor.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let sentinel = NSAttributedString.Key("GistPadAccentSentinel")
        editor.textStorage.addAttribute(sentinel, value: "retained", range: NSRange(location: 0, length: source.utf16.count))
        let attributes = NSAttributedString(attributedString: editor.attributedText)
        let selection = editor.selectedRange
        let offset = editor.contentOffset
        try await Task.sleep(for: .milliseconds(150))
        try #require(editor.attributedText.isEqual(to: attributes), "Establish stable attributed runs before changing only the accent.")
        host.rootView = sourceFixture(session: session, accent: "#A855F7")
        try await waitFor("updated source profile trait") {
            editor.traitCollection[PersonalAccentTrait.self].savedHex == "#A855F7"
        }
        try await Task.sleep(for: .milliseconds(150))
        let roles = PersonalAccent(savedHex: "#A855F7").roles(traits: editor.traitCollection)
        #expect(RGBColor(uiColor: editor.tintColor.resolvedColor(with: editor.traitCollection)) == roles.text)
        #expect(session.textView === editor)
        #expect(editor.window === window)
        #expect(editor.attributedText.isEqual(to: attributes))
        #expect(editor.selectedRange == selection)
        #expect(abs(editor.contentOffset.y - offset.y) <= 1)
        #expect(session.text.utf8.elementsEqual(source.utf8))
        #expect(session.generation == 0)
        #expect(sourceChanges == 0)
    }

    private func sourceFixture(session: DocumentSession, accent: String) -> some View {
        NavigationStack {
            MarkdownEditorView(session: session)
                .navigationTitle("A retained thought")
                .navigationBarTitleDisplayMode(.inline)
        }
        .personalAccent(savedHex: accent)
    }

    private func testWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return UIWindow(windowScene: scene)
    }

    private func waitFor(_ name: String, condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PreviewIntegrationFailure.timedOut(name)
    }
}

private enum PreviewIntegrationFailure: Error {
    case timedOut(String)
}
