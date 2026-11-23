#if canImport(UIKit)
    @testable import Editor
    import SwiftUI
    import Testing
    import UIKit

    @testable import GistPad

    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct IntelligenceSurfaceTests {
        @Test func closingIntelligenceRestoresSourceSelectionFocusAndUndo() async throws {
            let source =
                "# Saturday walk\n\nTake teh river path.\n"
                + (1...120).map { "Stop \($0) on the river path." }.joined(separator: "\n")
            let session = Editor(text: source)
            let editor = session.textView
            let selection = (source as NSString).range(of: "Stop 60 ")
            var changes = 0
            session.onEdit = { _, _ in changes += 1 }
            let presentation = IntelligencePresentation()
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(
                rootView: NavigationStack {
                    EditorView(editor: session).navigationTitle("Saturday walk")
                }
                .intelligenceSheet(presentation))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                if host.presentedViewController != nil {
                    await completion { host.dismiss(animated: false, completion: $0) }
                }
                window.endEditing(true)
                await keyboard(visible: false, over: host.view)
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            // Lays out the window and lets the sheet that starts opening or closing finish.
            func settle() async {
                window.layoutIfNeeded()
                await transitions(under: host)
                window.layoutIfNeeded()
            }
            window.layoutIfNeeded()
            try #require(editor.window === window && editor.bounds.height > 0)
            try #require(editor.becomeFirstResponder())
            // A writer reaches their place with the keyboard already up.
            await keyboard(visible: true, over: host.view)
            editor.selectedRange = selection
            editor.scrollRangeToVisible(selection)
            window.layoutIfNeeded()
            let offset = editor.contentOffset.y
            try #require(offset > 0)
            presentation.present(
                editor: session, title: "Saturday walk",
                revealSource: { _ in Issue.record("Closing must not navigate to a passage.") })
            try #require(presentation.target?.wasEditing == true)
            await settle()
            try #require(intelligencePrompt(presentedOver: host) != nil)
            #expect(!editor.isFirstResponder)
            presentation.target = nil
            await settle()
            // The closing sheet hands focus back to the editor it came from.
            await until { session.isEditing }
            await keyboard(visible: true, over: host.view)
            #expect(host.presentedViewController == nil)
            #expect(editor.isFirstResponder)
            #expect(session.textView === editor)
            #expect(editor.selectedRange == selection)
            #expect(abs(editor.contentOffset.y - offset) < 1)
            #expect(session.text.utf8.elementsEqual(source.utf8))
            #expect(session.generation == 0)
            #expect(changes == 0)

            editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
            editor.insertText("\nStill editable.")
            #expect(session.text.utf8.elementsEqual((source + "\nStill editable.").utf8))
            editor.undoManager?.undo()
            #expect(session.text.utf8.elementsEqual(source.utf8))
        }
    }

    /// The sheet's prompt field, found as a view because SwiftUI only builds
    /// accessibility identifiers while an accessibility client is running.
    func intelligencePrompt(presentedOver root: UIViewController) -> UITextView? {
        var presented = root.presentedViewController
        while let next = presented?.presentedViewController { presented = next }
        guard let sheet = presented, !sheet.isBeingPresented else { return nil }
        func find(in view: UIView) -> UITextView? {
            if let field = view as? UITextView { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(in: sheet.view)
    }
#endif
