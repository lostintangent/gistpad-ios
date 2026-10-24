import GistPadEditor
import GistPadPreview
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceState {
    var editing = ProcessInfo.processInfo.arguments.contains("editor")
    var focus = ProcessInfo.processInfo.arguments.contains("focus")
}

struct NotebookWorkspace: View {
    let session: DocumentSession
    @State var state = WorkspaceState()
    @State private var previewError: String?
    @State private var selection: String? = "phase-zero-editor"
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if state.focus {
                NavigationStack {
                    ArrangementView {
                        source
                    } secondary: {
                        preview
                    }
                    .arrangementViewStyle(.split)
                    .navigationTitle("Focus")
                    .toolbar { workspaceToolbar }
                    .safeAreaInset(edge: .bottom, spacing: 0) { diagnostics }
                }
            } else {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    library
                } detail: {
                    NavigationStack {
                        ZStack {
                            source
                                .opacity(state.editing ? 1 : 0)
                                .allowsHitTesting(state.editing)
                                .accessibilityHidden(!state.editing)
                            preview
                                .opacity(state.editing ? 0 : 1)
                                .allowsHitTesting(!state.editing)
                                .accessibilityHidden(state.editing)
                        }
                        .navigationTitle("The shape of a notebook")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { workspaceToolbar }
                        .safeAreaInset(edge: .bottom, spacing: 0) { diagnostics }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .tint(accent)
        .alert("Preview action", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("OK") { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
    }

    private var source: some View {
        MarkdownEditorView(session: session)
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !state.focus {
                Button {
                    state.editing.toggle()
                } label: {
                    if state.editing {
                        Label("Read", systemImage: "doc.richtext")
                    } else {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                }
                .accessibilityIdentifier("toggle-edit")
            }
            Button {
                state.focus.toggle()
            } label: {
                if state.focus {
                    Label("Library", systemImage: "sidebar.left")
                } else {
                    Label("Focus", systemImage: "rectangle.split.2x1")
                }
            }
            .accessibilityIdentifier("toggle-focus")
        }
    }

    private var library: some View {
        List(selection: $selection) {
            Section {
                Label("Today", systemImage: "sun.max")
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Daily notes are not connected in this editor spike")
            }
            Section("Synthetic notes") {
                NavigationLink(value: session.documentID) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The shape of a notebook")
                            .font(.headline)
                        Text("Unicode, composition & continuity")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            Section {
                Label("No account connected", systemImage: "person.crop.circle")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Phase 0 uses a synthetic note. Your GitHub account is untouched.")
            }
        }
        .navigationTitle("GistPad")
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
    }

    private var preview: some View {
        MarkdownPreviewView(document: session.text, documentID: session.documentID, generation: session.generation) { event in
            switch event {
            case .taskToggle(let edit):
                do {
                    try edit.validate(in: session.text, documentID: session.documentID, generation: session.generation)
                    try session.apply(
                        SourceMutation(range: edit.range, expected: edit.expectedMarker, replacement: edit.replacementMarker),
                        documentID: edit.documentID,
                        generation: edit.generation
                    )
                } catch {
                    previewError = error.localizedDescription
                }
            case .linkTapped(let link):
                if link.kind == .external, let url = URL(string: link.target) {
                    openURL(url)
                } else if link.kind == .wikilink {
                    previewError = "Wikilink received: \(link.target). Library lookup is not connected in this spike."
                }
            case .failure(let failure):
                previewError = failure.localizedDescription
            case .contentHeight, .rendered:
                break
            }
        }
    }

    private var diagnostics: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text("Editor \(session.viewIdentity.uuidString.prefix(8))")
                    .accessibilityIdentifier("editor-identity")
                Text("Generation \(session.generation) · UTF-16 \(session.text.utf16.count)")
                Text("Selection \(session.selection.location):\(session.selection.length)")
                Text(session.isComposing ? "Composing" : "No marked text")
            }
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Label("Phase 0 · Changes are in memory only", systemImage: "hammer")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var accent: Color {
        switch (colorScheme, contrast) {
        case (.dark, .increased): Color(red: 1, green: 232.0 / 255, blue: 153.0 / 255)
        case (.dark, _): Color(red: 243.0 / 255, green: 210.0 / 255, blue: 106.0 / 255)
        case (_, .increased): Color(red: 87.0 / 255, green: 62.0 / 255, blue: 0)
        default: Color(red: 118.0 / 255, green: 88.0 / 255, blue: 0)
        }
    }
}
