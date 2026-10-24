#if DEBUG
import GistPadEditor
import GistPadInterface
import GistPadPreview
import SwiftUI

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
    private let captureState: String
    private let captureScreen: String
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
        let screen = argument("--capture-screen", default: "library")
        let state = argument("--capture-state", default: "populated")
        captureScreen = screen
        let token = argument("--capture-ready-token", default: "")
        readinessToken = UUID(uuidString: token) == nil ? nil : token
        captureState = state
        supportedState = ["populated", "empty", "error", "offline", "readonly"].contains(state)
        let model = LibraryModel(
            snapshot: state == "empty" ? .init(notes: []) : InterfaceFixtures.library,
            loadState: state == "error"
                ? .failed(message: "Synthetic connection failure. No account request was made.")
                : state == "offline" ? .offline : .ready
        )
        model.selectedNoteID = state == "empty" || screen == "library" ? nil : "shape"
        _library = State(initialValue: model)
        _compactColumn = State(initialValue: screen == "library" ? .sidebar : .detail)
        _previewError = State(initialValue: state == "error" ? "Synthetic preview failure. Your source is unchanged." : nil)
    }

    var body: some View {
        if supportedState {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                LibraryView(model: library, actions: libraryActions)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Text(actionMessage ?? "Synthetic library. No account connected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .systemBackground))
                    }
            } detail: {
                NavigationStack {
                    if library.selectedNoteID != nil {
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
            .onChange(of: library.selectedNoteID) {
                if library.selectedNoteID != nil { compactColumn = .detail }
            }
            .task {
                if captureScreen == "library", horizontalSizeClass == .regular, captureState != "empty" {
                    library.selectedNoteID = "shape"
                }
                if captureScreen == "library" || captureState == "error" {
                    await markReady()
                }
            }
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
        chrome.access = captureState == "readonly" ? .readOnly : .editable
        if let note = library.snapshot.notes.first(where: { $0.id == library.selectedNoteID }) {
            chrome.title = note.title
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
        .init {
            actionMessage = "Synthetic fixture refreshed. No network request was made."
        } create: {
            actionMessage = "Creating gists is not connected in this in-memory fixture."
        } today: {
            actionMessage = "Today is not connected in this in-memory fixture."
        }
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
        return actions
    }

    private var preview: some View {
        ZStack {
            MarkdownPreviewView(
                document: activeSession.text, documentID: activeSession.documentID,
                generation: activeSession.generation, onEvent: handlePreviewEvent
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
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gistpad-capture-\(readinessToken).ready")
            let data = try JSONSerialization.data(withJSONObject: [
                "screen": captureScreen, "state": captureState,
                "token": readinessToken, "previewError": previewError ?? ""
            ], options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "Capture readiness could not be recorded: \(error.localizedDescription)"
        }
    }
}
#endif
