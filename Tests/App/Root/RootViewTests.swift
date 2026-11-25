import Foundation
@testable import Editor
import Markdown
import Screens
import Platform
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad
@testable import Model
@testable import Store

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RootViewTests {
    @Test func reopeningPreviewThenEditKeepsTheSourceOnScreen() async throws {
        let source = """
            ---
            edit:
              instructions: >-
                Preserve the reading list's existing sections and entries.
            ---

            # A visible reading list

            """
            + (1...300).map { "\($0). A retained reading entry \($0)\n" }.joined()
            + "\nAn exact final source line."
        let other = "# Another note\n\nA different retained source."
        let fixture = try await ModelFixture(autosave: false) {
            $0.addGist(
                id: "reading", description: "Reading list",
                files: ["README.md": source, "Calendar.md": "# A second file"])
            $0.addGist(id: "other", description: "Another note", files: ["README.md": other])
        }
        let host = try await NavigationHost(fixture: fixture, sizeClass: .compact, mode: .preview)
        defer { await host.close() }
        var retained: UITextView?
        for id in ["reading", "other", "reading"] {
            let text = id == "reading" ? source : other
            host.model.open(rowID: id)
            await until { host.model.activeEditor?.file.gist?.id == id }
            await host.settle()
            let editor = try #require(host.editor(text: text))
            try #require(host.picker != nil)
            if id == "reading" {
                if let retained { #expect(editor === retained) } else { retained = editor }
            }
            if id == "other" {
                // Unfolding the Duo gives Split. Folding it again keeps the same source.
                let compactWidth = host.window.frame.width
                host.window.traitOverrides.horizontalSizeClass = .regular
                host.window.frame.size.width = 1180
                await host.settle()
                try #require(host.picker?.numberOfSegments == 3)
                host.layout.select(.split)
                await host.settle()
                try #require(host.isVisible(editor))
                host.window.traitOverrides.horizontalSizeClass = .compact
                host.window.frame.size.width = compactWidth
                await host.settle()
                try #require(host.picker?.numberOfSegments == 2)
                host.layout.select(.preview)
            }
            for showsPreview in [true, false] {
                let picker = try #require(host.picker)
                picker.selectedSegmentIndex = showsPreview ? picker.numberOfSegments - 1 : 0
                picker.sendActions(for: .valueChanged)
                await host.settle()
                if showsPreview {
                    let preview = try #require(host.descendants.compactMap { $0 as? WKWebView }.first)
                    #expect(try await host.renders("retained", in: preview))
                } else {
                    // Edit shows the source at the top and waits for a tap to raise the keyboard.
                    try #require(host.isVisible(editor))
                    await host.keyboard(visible: false)
                    let caret = try host.caret(in: editor)
                    let bar = try #require(host.descendants.compactMap { $0 as? UINavigationBar }.last)
                    let top = bar.convert(bar.bounds, to: host.window).maxY
                    #expect(!editor.isFirstResponder)
                    #expect(editor.text.utf8.elementsEqual(text.utf8))
                    #expect(
                        editor.selectedRange
                            == NSRange(location: MarkdownDocument(text).contentStart, length: 0))
                    #expect(caret.minY >= top - 1 && caret.minY < top + 40)
                }
            }
            host.returnToLibrary()
            await host.settle()
            #expect(host.isLibraryVisible)
        }
    }

    @Test func leavingANewBlankNoteLeavesNothingBehind() async throws {
        let fixture = try await ModelFixture {
            $0.addGist(id: "kept", description: "Kept", files: ["README.md": "A real note"])
        }
        let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
        defer { await host.close() }
        // Creating is local, so it works offline.
        fixture.fail()
        await host.model.open(.new)
        let first = try #require(host.model.activeEditor?.file.nextDraft)
        await host.settle()
        let blank = try #require(host.editor(text: ""))
        #expect(blank.isFirstResponder)
        #expect(blank.selectedRange == NSRange(location: 0, length: 0))
        await host.keyboard(visible: true)
        #expect(try host.caret(in: blank).maxY <= host.keyboardFrame.minY)
        fixture.restore()
        host.pending.link = .gist(id: "kept", filename: nil)
        await until {
            host.pending.link == nil && host.model.activeEditor?.file.gist?.id == "kept"
                && host.model.editors[first.id] == nil
        }
        await host.settle()
        #expect(host.editor(text: "A real note") != nil)
        #expect(host.model.state.selectedID == "kept")

        await host.model.open(.new)
        let second = try #require(host.model.activeEditor?.file.nextDraft)
        await host.settle()
        let secondBlank = try #require(host.editor(text: ""))
        #expect(secondBlank.isFirstResponder)
        await host.keyboard(visible: true)
        #expect(try host.caret(in: secondBlank).maxY <= host.keyboardFrame.minY)
        host.returnToLibrary()
        await host.settle()
        await until { host.model.activeEditor == nil }
        #expect(host.isLibraryVisible)
        let stored = try await fixture.store.drafts(accountID: fixture.account.id).map(\.id)
        #expect(!stored.contains(first.id) && !stored.contains(second.id))
        #expect(fixture.publishes.isEmpty)
    }

    @Test(arguments: [true, false])
    func returningToLibraryPublishesTheOutgoingNoteAndKeepsItsEditor(autosave: Bool) async throws {
        let fixture = try await ModelFixture(autosave: autosave) {
            $0.addGist(id: "a", description: "Current", files: ["README.md": "Current source"])
        }
        let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
        defer { await host.close() }
        await host.model.open(.gist(id: "a"))
        let file = try #require(host.model.activeEditor)
        await host.settle()
        let editor = try #require(host.editor(text: "Current source"))
        editor.becomeFirstResponder()
        editor.selectedRange = .init(location: 0, length: 0)
        let typed = ContinuousClock.now
        editor.insertText("Local ")
        await until { host.model.drafts.first { $0.gistID == "a" }?.text == "Local Current source" }
        host.returnToLibrary()
        await until { file.status == .published }
        #expect(fixture.onGitHub("a", "README.md") == "Local Current source")
        // Autosave waits five quiet seconds after typing, so a publish before then came from leaving.
        if autosave { #expect(ContinuousClock.now - typed < .seconds(5)) }
        await host.settle()
        #expect(host.isLibraryVisible)
        #expect(fixture.publishes == ["PATCH /gists/a"])
        #expect(host.model.state.selectedID == nil)
        #expect(!editor.isFirstResponder)
        let selection = editor.selectedRange
        host.pending.link = .gist(id: "a", filename: nil)
        await until { host.pending.link == nil && host.model.activeEditor?.file.gist?.id == "a" }
        await host.settle()
        #expect(host.editor(text: "Local Current source") === editor)
        #expect(!host.isLibraryVisible)
        #expect(editor.selectedRange == selection)
    }

    @Test func switchingNotesMidCompositionKeepsAndPublishesTheComposedText() async throws {
        let fixture = try await ModelFixture(autosave: false) {
            $0.addGist(id: "a", description: "First note", files: ["README.md": "First note source"])
            $0.addGist(id: "b", description: "Second note", files: ["README.md": "Second note source"])
        }
        let host = try await NavigationHost(fixture: fixture)
        defer { await host.close() }
        host.model.open(rowID: "a")
        await until { host.model.activeEditor?.file.gist?.id == "a" }
        let file = try #require(host.model.activeEditor)
        await host.settle()
        let first = try #require(host.editor(text: "First note source"))
        try #require(first.becomeFirstResponder())
        first.selectedRange = NSRange(location: 0, length: 0)
        first.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
        try #require(first.markedTextRange != nil)
        host.model.open(rowID: "b")
        await until { host.model.activeEditor?.file.gist?.id == "b" }
        await host.settle()
        #expect(host.editor(text: "Second note source") != nil)
        #expect(first.markedTextRange == nil)
        #expect(first.text == "にほんごFirst note source")
        await until { file.status == .published }
        #expect(fixture.onGitHub("a", "README.md") == "にほんごFirst note source")
        #expect(fixture.publishes == ["PATCH /gists/a"])
    }

    @Test func startingTodayFocusesTheCaretAfterItsDurableInitialContent() async throws {
        let fixture = try await ModelFixture()
        let host = try await NavigationHost(fixture: fixture)
        defer { await host.close() }
        await host.model.open(.today())
        let draft = try #require(host.model.activeEditor?.file.nextDraft)
        #expect(!draft.text.isEmpty)
        await host.settle()
        let editor = try #require(host.editor(text: draft.text))
        #expect(editor.isFirstResponder)
        #expect(editor.selectedRange == NSRange(location: draft.text.utf16.count, length: 0))
        #expect(fixture.publishes.isEmpty)
    }

    @Test func aColdLinkWaitsForRestorationAndOpensTheExactFile() async throws {
        let fixture = try await ModelFixture {
            $0.addGist(
                id: "b", description: "Routed note",
                files: ["README.md": "Text", "Ideas.md": "Routed file source"])
        }
        let pending = PendingLink()
        pending.link = .gist(id: "b", filename: "Ideas.md")
        let host = try await NavigationHost(fixture: fixture, pending: pending)
        defer { await host.close() }
        await until { pending.link == nil && host.model.activeEditor?.file.filename == "Ideas.md" }
        await host.settle()
        #expect(host.editor(text: "Routed file source") != nil)
        #expect(host.model.activeEditor?.file.gist?.id == "b")
    }

    /// A widget's Today opens on a folded phone at a cold launch without waiting for GitHub: at once
    /// when you've written in it on this iPhone, and behind its placeholder while GitHub stages it.
    @Test(arguments: [true, false])
    func aColdTodayLinkOpensWithoutWaitingForGitHub(writtenOnThisIPhone: Bool) async throws {
        let today = DailyNote.filename()
        let fixture = try await ModelFixture {
            $0.addGist(
                id: "daily", description: DailyNote.gistDescription,
                files: [DailyNote.filename(date: .now - 86_400): "- [x] Yesterday's task\n"])
        }
        var text = "# \(today.dropLast(3))\n\n"
        if writtenOnThisIPhone {
            await fixture.model.start()
            text = "Written on this iPhone"
            _ = try await fixture.stageEdit(gistID: "daily", filename: today, text: text)
        }
        let github = fixture.hold("GET /gists")
        let pending = PendingLink()
        pending.link = .today
        let host = try await NavigationHost(
            fixture: fixture, model: fixture.relaunch(), pending: pending, sizeClass: .compact,
            waitsForStart: false)
        defer {
            github.open()
            await host.close()
        }
        try await github.arrival()
        await until { host.model.opening != nil || host.model.activeEditor != nil }
        await host.settle()
        #expect(!host.isLibraryVisible)
        #expect(!github.hasReachedGitHub)
        if !writtenOnThisIPhone { github.open() }
        await until { pending.link == nil && host.model.activeEditor?.file.filename == today }
        await host.settle()
        #expect(host.editor(text: text)?.isFirstResponder == true)
    }

    /// Opening early doesn't mean deciding from a stale library: today started on the web since
    /// the last launch opens from GitHub while the launch's refresh is still out.
    @Test func aColdTodayLinkOpensTodayFromTheWebOverAStaleLibrary() async throws {
        let today = DailyNote.filename()
        let fixture = try await ModelFixture(
            lastOpened: .gist(id: "a", filename: "README.md")
        ) {
            $0.addGist(
                id: "daily", description: DailyNote.gistDescription,
                files: [DailyNote.filename(date: .now - 86_400): "- [x] Yesterday's task\n"])
            $0.addGist(id: "a", description: "Last opened", files: ["README.md": "Last opened"])
        }
        await fixture.model.start()
        fixture.server.edit("daily", files: [today: "Started on the web"])
        let refresh = fixture.hold("GET /gists/starred")
        let pending = PendingLink()
        pending.link = .today
        let host = try await NavigationHost(
            fixture: fixture, model: fixture.relaunch(), pending: pending, sizeClass: .compact,
            waitsForStart: false)
        defer {
            refresh.open()
            await host.close()
        }
        try await refresh.arrival()
        await until { pending.link == nil && host.model.activeEditor?.file.filename == today }
        #expect(host.model.activeEditor?.editor.document.text == "Started on the web")
        await host.settle()
        #expect(host.editor(text: "Started on the web") != nil)
        #expect(!refresh.hasReachedGitHub)
    }

    @Test func splitNeedsRoomForTwoPanesBesideTheSidebar() async throws {
        let fixture = try await ModelFixture {
            $0.addGist(id: "a", description: "A", files: ["README.md": "Source"])
        }
        let host = try await NavigationHost(fixture: fixture, sizeClass: .regular, mode: .split)
        defer { await host.close() }
        // An open Duo is regular either way, but beside the sidebar its detail can't fit two panes.
        host.window.frame.size.width = 951
        await host.model.open(.gist(id: "a"))
        await host.settle()
        #expect(host.picker?.numberOfSegments == 2)
        try host.hideSidebar()
        await host.settle()
        #expect(host.picker?.numberOfSegments == 3)
    }

    @Test func aNewGistLinkOpensABlankNoteReadyToWrite() async throws {
        let fixture = try await ModelFixture {
            $0.addGist(id: "a", description: "Existing", files: ["README.md": "Existing source"])
        }
        let pending = PendingLink()
        pending.link = .newGist
        let host = try await NavigationHost(fixture: fixture, pending: pending)
        defer { await host.close() }
        await until { pending.link == nil && host.model.activeEditor != nil }
        await host.settle()
        #expect(host.editor(text: "")?.isFirstResponder == true)
        let draft = try #require(host.model.activeEditor?.file.nextDraft)
        #expect(!host.model.drafts.contains { $0.id == draft.id })
        #expect(host.model.activeEditor?.file.gist == nil)
        #expect(fixture.publishes.isEmpty)
    }

    @Test func aFailedOpenShowsItsOwnTitleAndRetryInsteadOfThePreviousEditor() async throws {
        let fixture = try await ModelFixture {
            $0.addGist(id: "a", description: "Previous", files: ["README.md": "Previous source"])
            $0.addGist(
                id: "b", description: "Requested",
                files: ["README.md": "Text", "Other.md": "Retried source"])
        }
        let host = try await NavigationHost(fixture: fixture)
        defer { await host.close() }
        await host.model.open(.gist(id: "a"))
        await host.settle()
        try #require(host.editor(text: "Previous source") != nil)
        fixture.fail("GET /gists/b")
        await host.model.open(.gist(id: "b", filename: "Other.md", rowID: "result-b"))
        await host.settle()
        #expect(host.titles.contains("Requested"))
        #expect(host.editor(text: "Previous source") == nil)
        fixture.restore()
        try await host.model.open(#require(host.model.opening).request)
        await host.settle()
        #expect(host.editor(text: "Retried source") != nil)
        #expect(accessibilityElement("note-open-retry", in: host.window) == nil)
        #expect(host.model.activeEditor?.file.gist?.id == "b")
        #expect(host.model.state.selectedID == "b")
        #expect(host.model.activeEditor?.file.filename == "Other.md")
    }

    @Test func sourceIntelligenceOpensTheLiveSheetForTheRetainedEditor() async throws {
        let fixture = try await ModelFixture(autosave: false) {
            $0.addGist(
                id: "a", description: "A retained thought", files: ["README.md": "A little room to think."])
        }
        let host = try await NavigationHost(fixture: fixture)
        defer { await host.close() }
        await host.model.open(.gist(id: "a"))
        await host.settle()
        let editor = try #require(host.editor(text: "A little room to think."))
        try #require(editor.becomeFirstResponder())
        let selection = NSRange(location: 2, length: 6)
        editor.selectedRange = selection
        let accessory = try #require(editor.inputAccessoryView)
        let entry = try #require(
            host.descendants(of: accessory).compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "editor-intelligence"
            })
        #expect(entry.isEnabled)
        entry.performPrimaryAction()
        await host.settle()
        try #require(intelligencePrompt(presentedOver: host.root) != nil)
        #expect(!editor.isFirstResponder)
        #expect(editor.selectedRange == selection)
        #expect(host.editor(text: "A little room to think.") === editor)
        #expect(fixture.publishes.isEmpty)
    }
}

/// The app's root view in a real window, around a fixture library.
private struct NavigationHost {
    let model: GistPadModel
    let window: UIWindow
    let root: UIViewController
    let pending: PendingLink
    let layout: LayoutPreferences
    private let suite: String
    private let previousWindow: UIWindow?

    init(
        fixture: ModelFixture, model: GistPadModel? = nil, pending: PendingLink = PendingLink(),
        sizeClass: UIUserInterfaceSizeClass? = nil, mode: FileMode = .edit, waitsForStart: Bool = true
    ) async throws {
        self.model = model ?? fixture.model
        self.pending = pending
        suite = "RootView-\(UUID())"
        layout = LayoutPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        layout.select(mode)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        let sceneBounds = scene.effectiveGeometry.coordinateSpace.bounds
        // A compact host is a phone even when the simulator is an open Duo.
        let width: CGFloat =
            switch sizeClass {
            case .regular: 1180
            case .compact: min(sceneBounds.width, 440)
            default: sceneBounds.width
            }
        window.frame = CGRect(
            origin: sceneBounds.origin, size: CGSize(width: width, height: sceneBounds.height))
        if let sizeClass { window.traitOverrides.horizontalSizeClass = sizeClass }
        root = UIHostingController(rootView: RootView(model: self.model, layout: layout, pending: pending))
        window.rootViewController = root
        window.makeKeyAndVisible()
        guard waitsForStart else { return }
        let model = self.model
        await until { model.phase == .ready && model.gistCache != nil }
    }

    /// Hides the Library, as the sidebar button does.
    func hideSidebar() throws {
        func splits(in controller: UIViewController) -> [UISplitViewController] {
            [controller as? UISplitViewController].compactMap(\.self) + controller.children.flatMap(splits)
        }
        // The comments inspector is a split view too, without a sidebar.
        let library = try #require(splits(in: root).first { $0.viewController(for: .primary) != nil })
        library.hide(.primary)
    }

    /// Lays out the window and lets the navigation that starts finish. SwiftUI updates as the
    /// window lays out, and a push or a sheet then runs under a transition coordinator.
    func settle() async {
        window.layoutIfNeeded()
        await transitions(under: root)
        window.layoutIfNeeded()
    }

    var descendants: [UIView] {
        descendants(of: window)
    }

    func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func editor(text: String) -> UITextView? {
        descendants.compactMap { $0 as? UITextView }.first { $0.text == text && $0.window === window }
    }

    /// The titles in the window's navigation bars.
    var titles: [String] {
        descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }
    }

    /// The file's Edit, Preview (and Split, when wide) control.
    var picker: UISegmentedControl? {
        descendants.compactMap { $0 as? UISegmentedControl }.last
    }

    /// Pops the pushed file the way the system back button does on iPhone.
    func returnToLibrary() {
        descendants.lazy.compactMap { $0.next as? UINavigationController }
            .first { $0.viewControllers.count > 1 }?
            .popViewController(animated: false)
    }

    var isLibraryVisible: Bool {
        let bars = descendants.compactMap { $0 as? UINavigationBar }.filter {
            $0.topItem?.title == "GistPad" && isVisible($0)
        }
        for bar in bars {
            let frame = bar.convert(bar.bounds, to: window)
            let viewport = window.bounds.inset(by: window.safeAreaInsets)
            let point = CGPoint(
                x: frame.intersection(viewport).midX, y: max(viewport.minY, frame.maxY) + 44)
            guard viewport.contains(point) else { continue }
            var hit = window.hitTest(point, with: nil)
            while let view = hit {
                if view is UICollectionView || view is UITableView { return true }
                hit = view.superview
            }
        }
        return false
    }

    func isVisible(_ view: UIView) -> Bool {
        guard view.window === window, !view.bounds.isEmpty else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return window.bounds.insetBy(dx: -0.5, dy: -0.5)
            .contains(view.convert(view.bounds, to: window))
    }

    var keyboardFrame: CGRect {
        root.view.convert(root.view.keyboardLayoutGuide.layoutFrame, to: window)
    }

    func caret(in editor: UITextView) throws -> CGRect {
        let position = try #require(editor.selectedTextRange?.end)
        return editor.convert(editor.caretRect(for: position), to: window)
    }

    /// Waits for the keyboard to come up or go away. The simulator's keyboard outlives each test and
    /// may be the software keyboard, a hardware keyboard's bar, or placed beside a host narrower than
    /// the scene, so tests check the caret against whichever frame it ends at.
    func keyboard(visible: Bool) async {
        await GistPadTests.keyboard(visible: visible, over: root.view)
    }

    /// Whether the preview shows `text`, once WebKit has loaded the page and the note has rendered.
    func renders(_ text: String, in preview: WKWebView) async throws -> Bool {
        let (loaded, finish) = AsyncStream<Never>.makeStream()
        let loading = preview.observe(\.isLoading, options: [.initial, .new]) { _, change in
            if change.newValue == false { finish.finish() }
        }
        for await _ in loaded {}
        loading.invalidate()
        return try await preview.callAsyncJavaScript(
            """
            const shows = () => document.body.innerText.includes(text);
            while (!shows()) {
                await new Promise(changed => new MutationObserver((_, observer) => {
                    observer.disconnect();
                    changed();
                }).observe(document.body, { childList: true, subtree: true, characterData: true }));
            }
            return true;
            """, arguments: ["text": text], in: nil, contentWorld: .page) as? Bool == true
    }

    func close() async {
        if root.presentedViewController != nil {
            await completion { root.dismiss(animated: false, completion: $0) }
        }
        // A closing sheet hands focus back to the file it came from, so the keyboard goes last.
        await settle()
        window.endEditing(true)
        await keyboard(visible: false)
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
