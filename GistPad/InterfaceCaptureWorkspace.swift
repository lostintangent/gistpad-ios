#if DEBUG
import GistPadEditor
import GistPadInterface
import GistPadPreview
import SwiftUI
import UIKit

struct InterfaceCaptureWorkspace: View {
    static let markdown = """
        # The shape of a notebook

        A quiet place to think, with a precise engine beneath the page.

        ## Keep the thought, not the interface

        Opening the notebook should leave the thought exactly where it was.
        A little more room can reveal the context without changing the task.

        - [x] Make reading feel effortless
        - [ ] Keep the next step close
        - [ ] Leave room for something unexpected

        > Good tools make space for the work.

        This is a **synthetic note** for interface review. Changes stay in memory.
        """

    let session: DocumentSession
    @State private var ideasSession = DocumentSession(
        documentID: "capture-ideas",
        text: "# Small observations\n\nA notebook can be both quiet and precise.\n\n- [ ] Follow the useful detail\n"
    )
    @State private var library: LibraryModel
    @State private var compactColumn: NavigationSplitViewColumn
    @State private var selectedFileID = "README.md"
    @State private var modes: [String: NoteMode] = [:]
    @State private var previewError: String?
    @State private var previewReload = 0
    @State private var actionMessage: String?
    @State private var showingTagEditor: Bool
    @State private var searchPresented = false
    @State private var searchKeyboardHeight: CGFloat = 0
    private let captureState: String
    private let captureScreen: String
    private let captureAccent: String?
    private let readinessToken: String?
    private let supportedState: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(session: DocumentSession) {
        self.session = session
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ name: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return fallback }
            return arguments[index + 1]
        }
        let screen = LaunchArguments.captureScreen ?? "library"
        let state = argument("--capture-state", default: "populated")
        let accent = argument("--capture-accent", default: "")
        captureAccent = accent.isEmpty ? nil : accent
        captureScreen = screen
        let token = argument("--capture-ready-token", default: "")
        readinessToken = UUID(uuidString: token) == nil ? nil : token
        captureState = state
        supportedState = [
            "populated", "empty", "error", "offline", "readonly", "tag-audit", "today",
            "tag-editor", "tag-readonly", "search", "search-active", "no-results", "filtered", "signed-out",
            "daily", "starred", "archive", "notes", "featured"
        ].contains(state)
        _showingTagEditor = State(initialValue: state == "tag-editor" || state == "tag-readonly")
        var snapshot = state == "empty" ? LibrarySnapshot(notes: []) : InterfaceFixtures.library
        if state != "empty" {
            snapshot.notes.insert(
                .init(
                    id: "small", title: "Small observations", updatedAt: InterfaceFixtures.referenceDate,
                    isPinned: true, tagIDs: ["ideas"], fileCount: 1,
                    excerpt: "A notebook can be both quiet and precise."
                ),
                at: 1
            )
            if let index = snapshot.notes.firstIndex(where: { $0.id == "shape" }) {
                snapshot.notes[index].fileCount = 2
                snapshot.notes[index].excerpt = "A quiet place to think, with a precise engine beneath the page."
            }
            if let index = snapshot.notes.firstIndex(where: { $0.id == "weekend" }) {
                snapshot.notes[index].excerpt = "Leave a little room for an unplanned afternoon."
                snapshot.notes[index].fileCount = 1
            }
            if let index = snapshot.notes.firstIndex(where: { $0.id == "words" }) {
                snapshot.notes[index].excerpt = "A few sentences to return to when a thought needs a starting point."
                snapshot.notes[index].fileCount = 3
            }
        }
        if state == "tag-audit" {
            snapshot = LibrarySnapshot(
                notes: [
                    .init(
                        id: "shape", title: "Labels with room", updatedAt: InterfaceFixtures.referenceDate,
                        isPinned: true, tagIDs: ["long", "yellow", "missing"]
                    ),
                    .init(
                        id: "white-black", title: "Black and white", updatedAt: InterfaceFixtures.referenceDate,
                        tagIDs: ["black", "white"]
                    ),
                    .init(
                        id: "missing-color", title: "An unspecified color", updatedAt: InterfaceFixtures.referenceDate,
                        tagIDs: ["missing"]
                    )
                ],
                tags: [
                    .init(id: "long", name: "A longer label that must wrap, not truncate", colorHex: "#548C80"),
                    .init(id: "yellow", name: "Bright yellow", colorHex: "#FFFF00"),
                    .init(id: "white", name: "White", colorHex: "#FFFFFF"),
                    .init(id: "black", name: "Black", colorHex: "#000000"),
                    .init(id: "missing", name: "No color")
                ]
            )
        }
        if LaunchArguments.captureReadingFixture,
           let index = snapshot.notes.firstIndex(where: { $0.id == "shape" }) {
            snapshot.notes[index].title = "A considered page"
        }
        let model = LibraryModel(
            snapshot: snapshot,
            loadState: state == "error"
                ? .failed(message: "Synthetic connection failure. No account request was made.")
                : state == "offline" ? .offline : state == "signed-out" ? .signedOut : .ready,
            today: .init(
                date: InterfaceFixtures.referenceDate,
                progress: state == "empty" || state == "today" ? nil : .init(completed: 1, total: 3),
                availability: state == "empty" || state == "today" ? .missing : .existing,
                excerpt: state == "empty" || state == "today" ? nil : "Keep the thought, not the interface."
            )
        )
        switch state {
        case "daily": model.collection = .dailyNotes
        case "starred": model.collection = .starred
        case "archive": model.collection = .archive
        case "filtered": model.selectedTagIDs = ["ideas"]
        case "search", "search-active":
            model.query = "notebook"
            model.searchState = .results(
                notes: snapshot.notes.filter { ["shape", "small"].contains($0.id) },
                coverage: .init(totalDocuments: snapshot.notes.count, documentsWithCachedContent: 2)
            )
        case "no-results":
            model.query = "No matching synthetic words"
            model.searchState = .results(
                notes: [],
                coverage: .init(totalDocuments: snapshot.notes.count, documentsWithCachedContent: 2)
            )
        default: break
        }
        model.selectedNoteID = state == "empty" || state == "today" || screen == "library" ? nil : "shape"
        _library = State(initialValue: model)
        _compactColumn = State(initialValue: screen == "library" ? .sidebar : .detail)
        _previewError = State(initialValue: state == "error" ? "Synthetic preview failure. Your source is unchanged." : nil)
    }

    var body: some View {
        if supportedState {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                ScrollViewReader { scroll in
                    LibraryView(
                        model: library, actions: libraryActions,
                        footer: Text(actionMessage ?? "Synthetic library. No account connected."),
                        isTodaySelected: captureState == "today",
                        isSidebar: horizontalSizeClass == .regular
                    )
                    .task {
                        if captureState == "notes" || captureState == "featured" {
                            try? await Task.sleep(for: .milliseconds(400))
                            scroll.scrollTo(captureState == "notes" ? "weekend" : "shape", anchor: .top)
                            await markReady()
                        }
                    }
                }
            } detail: {
                NavigationStack {
                    if captureState == "today" {
                        TodayLanding(summary: library.today) {
                            actionMessage = "This synthetic landing cannot create a note."
                        }
                    } else if library.selectedNoteID != nil {
                        NoteScreen(
                            document: chrome, mode: mode, saveState: .inMemoryFixture,
                            actions: noteActions
                        ) {
                            MarkdownEditorView(session: activeSession)
                        } preview: {
                            preview
                        }
                    } else {
                        ContentUnavailableView("Select a gist", systemImage: "doc.text")
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .librarySearch(
                model: library,
                isPresented: captureState == "search-active" ? $searchPresented : nil
            )
            .sheet(isPresented: $showingTagEditor) {
                TagEditor(
                    tags: library.snapshot.tags, selectedTagIDs: Set(chrome.tags.map(\.id)),
                    save: captureTagSave
                )
            }
            .onChange(of: library.selectedNoteID) {
                if library.selectedNoteID != nil { compactColumn = .detail }
            }
            .task {
                if captureState == "search-active" { searchPresented = true }
                if captureScreen == "library", horizontalSizeClass == .regular, captureState != "empty" {
                    library.selectedNoteID = "shape"
                }
                if (captureScreen == "library" && !["notes", "featured"].contains(captureState))
                    || captureState == "error" || captureState == "today" {
                    await markReady()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
                guard captureState == "search-active",
                      let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
                else { return }
                searchKeyboardHeight = max(0, scene.effectiveGeometry.coordinateSpace.bounds.intersection(frame).height)
                Task { await markReady() }
            }
            .personalAccent(savedHex: captureAccent)
        } else {
            ContentUnavailableView(
                "Unknown capture state", systemImage: "exclamationmark.triangle",
                description: Text(captureState)
            )
        }
    }

    private var activeSession: DocumentSession {
        selectedFileID == "Ideas.md" ? ideasSession : session
    }

    private var chrome: NoteChrome {
        var chrome = InterfaceFixtures.note
        chrome.selectedFileID = selectedFileID
        chrome.access = ["readonly", "tag-readonly"].contains(captureState) ? .readOnly : .editable
        if let note = library.snapshot.notes.first(where: { $0.id == library.selectedNoteID }) {
            chrome.title = note.title
            chrome.tags = library.tags(for: note)
        }
        return chrome
    }

    private var mode: Binding<NoteMode> {
        Binding(
            get: { modes[selectedFileID] ?? .reading },
            set: { modes[selectedFileID] = $0 }
        )
    }

    private var libraryActions: LibraryActions {
        var actions = LibraryActions {
            actionMessage = "Synthetic fixture refreshed. No network request was made."
        } create: {
            actionMessage = "Creating gists is not connected in this in-memory fixture."
        } today: {
            actionMessage = "Today is not connected in this in-memory fixture."
        }
        actions.reconnect = {
            actionMessage = "This synthetic invitation does not connect to GitHub."
        }
        return actions
    }

    private var noteActions: NoteActions {
        var actions = NoteActions()
        actions.selectFile = { filename in
            activeSession.textView.resignFirstResponder()
            selectedFileID = filename
            previewError = nil
        }
        actions.didChangeMode = { mode in
            if mode == .source {
                activeSession.textView.becomeFirstResponder()
            } else {
                activeSession.textView.resignFirstResponder()
            }
        }
        actions.find = {
            mode.wrappedValue = .source
            activeSession.presentFind(replacing: true)
        }
        return actions
    }

    private var captureTagSave: (@MainActor ([TagEdit]) async throws -> Void)? {
        guard captureState == "tag-editor" else { return nil }
        return { _ in throw CaptureTagSaveFailure() }
    }

    private var preview: some View {
        ZStack {
            MarkdownPreviewView(
                document: activeSession.text, documentID: activeSession.documentID,
                generation: activeSession.generation, allowsTaskEdits: chrome.access.canEdit,
                onEvent: handlePreviewEvent
            )
            .id("\(activeSession.documentID)-\(previewReload)")
            .accessibilityHidden(previewError != nil)
            .allowsHitTesting(previewError == nil)
            if let previewError {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(previewError)
                } actions: {
                    Button("Retry") {
                        self.previewError = nil
                        previewReload += 1
                    }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private func handlePreviewEvent(_ event: PreviewEvent) {
        switch event {
        case .taskToggle(let edit):
            guard chrome.access.canEdit else {
                previewError = "This read-only fixture cannot change a task."
                return
            }
            do {
                try edit.validate(
                    in: activeSession.text, documentID: activeSession.documentID, generation: activeSession.generation
                )
                try activeSession.apply(
                    SourceMutation(range: edit.range, expected: edit.expectedMarker, replacement: edit.replacementMarker),
                    documentID: edit.documentID, generation: edit.generation
                )
            } catch {
                previewError = "The task could not be changed. \(error.localizedDescription)"
            }
        case .failure(let failure):
            previewError = failure.localizedDescription
            Task { await markReady() }
        case .linkTapped(let link):
            if link.kind == .external, let url = URL(string: link.target) {
                openURL(url)
            } else {
                previewError = "This synthetic fixture does not resolve linked notes."
            }
        case .rendered:
            Task { await markReady() }
        case .contentHeight:
            break
        }
    }

    private func markReady() async {
        guard let readinessToken else { return }
        do {
            try await Task.sleep(for: .milliseconds(500))
            let searchFocused = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .filter { !$0.isHidden }
                .contains { hasFocusedSearch(in: $0) }
            // A hardware-keyboard shortcut bar is not a software-keyboard capture.
            let searchKeyboardVisible = searchKeyboardHeight >= 150
            guard captureState != "search-active" || (searchFocused && searchKeyboardVisible) else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gistpad-capture-\(readinessToken).ready")
            let data = try JSONSerialization.data(withJSONObject: [
                "screen": captureScreen, "state": captureState,
                "accent": captureAccent ?? "",
                "searchFocused": searchFocused, "searchKeyboardVisible": searchKeyboardVisible,
                "searchKeyboardHeight": searchKeyboardHeight,
                "fixture": LaunchArguments.captureReadingFixture ? "reading-polish" : "notebook",
                "token": readinessToken, "previewError": previewError ?? ""
            ], options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "Capture readiness could not be recorded: \(error.localizedDescription)"
        }
    }

    private func hasFocusedSearch(in view: UIView) -> Bool {
        if let field = view as? UITextField, field.isFirstResponder, field.text == library.query {
            return true
        }
        return view.subviews.contains { hasFocusedSearch(in: $0) }
    }
}

private struct CaptureTagSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Synthetic tag save failure. Your choices remain in this sheet. No account request was made."
    }
}
#endif
