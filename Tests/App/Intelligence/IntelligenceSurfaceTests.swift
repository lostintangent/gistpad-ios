#if canImport(UIKit)
    @testable import Editor
    import SwiftUI
    import Testing
    import UIKit

    @testable import GistPad
    @testable import Intelligence

    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct IntelligenceSurfaceTests {
        @Test func closingIntelligenceRestoresSourceSelectionFocusAndUndo() async throws {
            let source =
                "# Saturday walk\n\nTake teh river path.\n"
                + (1...120).map { "Stop \($0) on the river path." }.joined(separator: "\n")
            let session = MarkdownEditor(text: source)
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
                    MarkdownEditorView(editor: session).navigationTitle("Saturday walk")
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
            #expect(session.document.text.utf8.elementsEqual(source.utf8))
            #expect(session.generation == 0)
            #expect(changes == 0)

            editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
            editor.insertText("\nStill editable.")
            #expect(session.document.text.utf8.elementsEqual((source + "\nStill editable.").utf8))
            editor.undoManager?.undo()
            #expect(session.document.text.utf8.elementsEqual(source.utf8))
        }

        @Test func applyIsOneUndoThatKeepsTheTypingBeforeIt() async throws {
            let source = "Take teh river path.\nLeave at 9am, before the cafe opens at 8am."
            let editor = MarkdownEditor(text: source)
            let window = try host(editor)
            defer {
                window.endEditing(true)
                await keyboard(visible: false, over: window)
                window.isHidden = true
            }
            let undo = try #require(editor.textView.undoManager)
            undo.removeAllActions()
            editor.textView.selectedRange = NSRange(location: source.utf16.count, length: 0)
            editor.textView.insertText("!")
            editor.textViewDidChange(editor.textView)
            await undoGroupCloses(in: undo)
            let typed = source + "!"
            let snapshot = editor.snapshot()
            let note = NSRange(location: 0, length: snapshot.source.utf16.count)
            let proposal = Proposal(
                snapshot: snapshot,
                scopedCandidates: [
                    (Proposal.Change(quote: "teh", replacement: "the", reason: "Spelling."), note),
                    (Proposal.Change(quote: "before", replacement: "after", reason: "Timing."), note),
                ])

            // Apply runs while the sheet's prompt field has the keyboard.
            let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
            window.rootViewController?.view.addSubview(field)
            #expect(field.becomeFirstResponder())
            let selection = editor.textView.selectedRange
            _ = try editor.apply(proposal)
            let edited = "Take the river path.\nLeave at 9am, after the cafe opens at 8am.!"
            #expect(editor.document.text == edited)

            field.resignFirstResponder()
            #expect(editor.textView.becomeFirstResponder())
            #expect(editor.textView.undoManager === undo)
            for expected in [typed, source] {
                undo.undo()
                editor.textViewDidChange(editor.textView)
                #expect(editor.document.text == expected)
                if expected == typed { #expect(editor.textView.selectedRange == selection) }
            }
            for expected in [typed, edited] {
                undo.redo()
                editor.textViewDidChange(editor.textView)
                #expect(editor.document.text == expected)
            }
        }

        /// Returns once the undo group that typing opened closes at the end of the run loop's pass,
        /// as it does between a keystroke and a tap on Apply.
        private func undoGroupCloses(in undo: UndoManager) async {
            guard undo.groupingLevel > 0 else { return }
            let (closed, close) = AsyncStream<Never>.makeStream()
            let center = NotificationCenter.default
            let token = center.addObserver(of: undo, for: .didCloseUndoGroup) { _ in close.finish() }
            defer { center.removeObserver(token) }
            for await _ in closed {}
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
