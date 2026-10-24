#if os(iOS)
import GistPadAppearance
import GistPadEditor
import GistPadPreview
import SwiftUI

public struct DocumintSpikeWorkspace: View {
    private enum Mode: String, CaseIterable { case source = "Edit", rich = "Rich", preview = "Preview" }
    private let session: DocumentSession
    @State private var mode = Mode.rich
    @State private var failure: String?
    @State private var paintMS: Double?
    @State private var openedAt = ContinuousClock.now
    @State private var hasOpenedRich = true

    public init(session: DocumentSession) {
        self.session = session
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--documint-mode"), arguments.indices.contains(index + 1) {
            let preview = arguments[index + 1] == "preview"
            _mode = State(initialValue: preview ? .preview : .rich)
            _hasOpenedRich = State(initialValue: !preview)
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                MarkdownEditorView(session: session)
                    .environment(\.isNotebookPaneVisible, mode == .source)
                    .opacity(mode == .source ? 1 : 0)
                    .allowsHitTesting(mode == .source)
                    .accessibilityHidden(mode != .source)
                if hasOpenedRich {
                    DocumintSpikeView(session: session, isActive: mode == .rich,
                        onFailure: { failure = $0 }, onRendered: {
                            paintMS = $0
                            if mode == .rich { recordReady() }
                        })
                        .opacity(mode == .rich ? 1 : 0)
                        .allowsHitTesting(mode == .rich)
                        .accessibilityHidden(mode != .rich)
                }
                if mode == .preview {
                    MarkdownPreviewView(
                        document: session.text, documentID: session.documentID, generation: session.generation,
                        allowsTaskEdits: session.canFormat, onEvent: { handlePreview($0) }
                    )
                }
            }
            .navigationTitle("Rich editor spike")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Note mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("Local spike · \(session.generation) edits\(paintMS.map { " · \(Int($0)) ms" } ?? "")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let failure {
                    Text(failure).font(.callout).padding().frame(maxWidth: .infinity)
                        .background(.regularMaterial).accessibilityAddTraits(.isStaticText)
                }
            }
            .onChange(of: mode) { _, next in
                session.textView.resignFirstResponder()
                if next == .rich { hasOpenedRich = true }
                if next == .source { session.requestFocusAtContentStart() }
            }
        }
        .tint(.primary)
    }

    private func handlePreview(_ event: PreviewEvent) {
        switch event {
        case .taskToggle(let edit):
            do {
                try edit.validate(in: session.text, documentID: session.documentID, generation: session.generation)
                try session.apply(
                    SourceMutation(range: edit.range, expected: edit.expectedMarker, replacement: edit.replacementMarker),
                    documentID: edit.documentID, generation: edit.generation
                )
            } catch { failure = error.localizedDescription }
        case .failure(let error): failure = error.localizedDescription
        case .linkTapped:
            failure = "Links are disabled in this local, account-free spike."
        case .rendered:
            if mode == .preview { recordReady() }
        case .contentHeight: break
        }
    }

    private func recordReady() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--documint-ready-token"),
              arguments.indices.contains(index + 1)
        else { return }
        guard let token = UUID(uuidString: arguments[index + 1]) else {
            failure = "The spike readiness token is invalid."
            return
        }
        do {
            let folder = URL.applicationSupportDirectory.appendingPathComponent("DocumintSpike", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let elapsed = openedAt.duration(to: .now).components
            let payload: [String: Any] = [
                "mode": mode.rawValue, "token": token.uuidString,
                "hostToRenderedMS": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            ]
            try JSONSerialization.data(withJSONObject: payload).write(
                to: folder.appendingPathComponent("ready-\(token.uuidString).json"), options: .atomic
            )
        } catch { failure = error.localizedDescription }
    }
}
#endif
