import GistPadEditor
import GistPadPreview
import SwiftUI

@main
struct GistPadApp: App {
    @State private var session: DocumentSession?
    @State private var loadError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let session {
                    NotebookWorkspace(session: session)
                        .alert("Phase 0", isPresented: Binding(
                            get: { loadError != nil },
                            set: { if !$0 { loadError = nil } }
                        )) {
                            Button("OK") { loadError = nil }
                        } message: {
                            Text(loadError ?? "")
                        }
                } else if let loadError {
                    ContentUnavailableView("Fixture could not open", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView("Opening notebook")
                }
            }
            .task {
                guard session == nil else { return }
                do {
                    let arguments = ProcessInfo.processInfo.arguments
                    let longFixture = arguments.contains("--long-fixture") || arguments.contains("editor")
                    let text = try longFixture ? EditorFixture.markdown() : PreviewFixtures.allSyntax
                    session = DocumentSession(documentID: "phase-zero-editor", text: text)
                } catch {
                    loadError = error.localizedDescription
                }
            }
            .onOpenURL { url in
                // Authentication is not wired in the editor spike.
                if url.scheme == "gistpad" {
                    loadError = "Authentication callback received. Sign-in is not implemented in this Phase 0 build."
                }
            }
        }
    }
}
