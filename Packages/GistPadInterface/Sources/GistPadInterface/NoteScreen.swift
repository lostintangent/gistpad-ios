#if os(iOS)
import SwiftUI

public struct NoteScreen<Source: View, Preview: View>: View {
    private let document: NoteChrome
    @Binding private var mode: NoteMode
    private let saveState: NoteSaveState
    private let actions: NoteActions
    private let source: Source
    private let preview: Preview
    @State private var showingFiles = false
    @State private var showingTags = false
    @State private var pendingFileAction: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showingSource: Bool { mode == .source && document.access.canEdit }
    private var showsFiles: Bool {
        document.files.count > 1 || (document.access.canEdit && (actions.addFile != nil || actions.renameFile != nil))
    }

    public init(
        document: NoteChrome, mode: Binding<NoteMode>, saveState: NoteSaveState,
        actions: NoteActions = .init(),
        @ViewBuilder source: () -> Source, @ViewBuilder preview: () -> Preview
    ) {
        self.document = document
        self._mode = mode
        self.saveState = saveState
        self.actions = actions
        self.source = source()
        self.preview = preview()
    }
    public var body: some View {
        ZStack {
            source
                .opacity(showingSource ? 1 : 0)
                .allowsHitTesting(showingSource)
                .accessibilityHidden(!showingSource)
            preview
                .opacity(showingSource ? 0 : 1)
                .allowsHitTesting(!showingSource)
                .accessibilityHidden(showingSource)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if showsFiles {
                Button(String(localized: "Files in this gist", bundle: .module), systemImage: "doc.on.doc") {
                    showingFiles = true
                }
            }
            if let rename = actions.rename, document.access.canEdit {
                Button(String(localized: "Rename", bundle: .module), systemImage: "pencil", action: rename)
            }
        }
        .toolbar { noteToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            status
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showingFiles, onDismiss: {
            let action = pendingFileAction
            pendingFileAction = nil
            action?()
        }) { files }
        .sheet(isPresented: $showingTags) {
            TagEditor(tags: document.tags, selectedTagIDs: Set(document.tags.map(\.id)))
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onChange(of: document.selectedFileID) { showingFiles = false }
        .onChange(of: showingSource) {
            actions.didChangeMode?(showingSource ? .source : .reading)
        }
    }

    @ToolbarContentBuilder
    private var noteToolbar: some ToolbarContent {
        primaryToolbar
        secondaryToolbar
    }

    @ToolbarContentBuilder
    private var primaryToolbar: some ToolbarContent {
        if document.access.canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    mode = mode == .reading ? .source : .reading
                } label: {
                    Label(
                        mode == .reading ? String(localized: "Edit", bundle: .module) : String(localized: "Preview", bundle: .module),
                        systemImage: mode == .reading ? "square.and.pencil" : "doc.richtext"
                    )
                }
                .accessibilityIdentifier("note-toggle-mode")
            }
        }
        if let save = actions.save, document.access.canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Save to GitHub", bundle: .module), systemImage: "arrow.up.doc", action: save)
                    .disabled(!saveState.canPublish)
                    .accessibilityIdentifier("note-save")
            }
        }
    }

    @ToolbarContentBuilder
    private var secondaryToolbar: some ToolbarContent {
        if let share = actions.share {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up", action: share)
            }
        }
        if showsFiles {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Files in this gist", bundle: .module), systemImage: "doc.on.doc") {
                    showingFiles = true
                }
            }
        }
        if let focus = actions.focus {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Source & Preview", bundle: .module), systemImage: "rectangle.split.2x1", action: focus)
                    .disabled(!document.access.canEdit)
            }
        }
        if let tags = actions.tags {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Tags", bundle: .module), systemImage: "tag", action: tags)
            }
        } else if !document.tags.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Tags", bundle: .module), systemImage: "tag") { showingTags = true }
            }
        }
        if let pin = actions.togglePin {
            ToolbarItem(placement: .secondaryAction) {
                Button(
                    document.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                    systemImage: document.isPinned ? "pin.slash" : "pin", action: pin
                )
            }
        }
        if let star = actions.toggleStar {
            ToolbarItem(placement: .secondaryAction) {
                Button(
                    document.isStarred ? String(localized: "Unstar", bundle: .module) : String(localized: "Star", bundle: .module),
                    systemImage: document.isStarred ? "star.slash" : "star", action: star
                )
            }
        }
        if let archive = actions.toggleArchive {
            ToolbarItem(placement: .secondaryAction) {
                Button(
                    document.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                    systemImage: "archivebox", action: archive
                )
            }
        }
        if let delete = actions.delete, document.access.canEdit {
            ToolbarItem(placement: .secondaryAction) {
                Button(
                    String(localized: "Delete gist", bundle: .module),
                    systemImage: "trash", role: .destructive, action: delete
                )
            }
        }
        if let copy = actions.copyLink {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Copy Link", bundle: .module), systemImage: "link", action: copy)
            }
        }
        if let open = actions.openInGitHub {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Open in GitHub", bundle: .module), systemImage: "arrow.up.right", action: open)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if document.access == .truncated {
                Label(
                    String(localized: "GitHub returned an incomplete note. Editing is unavailable to protect the original.", bundle: .module),
                    systemImage: "exclamationmark.shield"
                )
            } else if document.access == .readOnly {
                Label(String(localized: "Read-only note", bundle: .module), systemImage: "eye")
            }
            saveStatus
        }
        .font(.footnote)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("note-save-state")
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: saveState)
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch saveState {
        case .inMemoryFixture:
            Text("In-memory fixture. Not saved.", bundle: .module)
        case .unsaved:
            Label(String(localized: "Not saved yet", bundle: .module), systemImage: "doc")
        case .savedLocally:
            Label(String(localized: "Saved on this iPhone", bundle: .module), systemImage: "iphone")
        case .savingToGitHub:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving to GitHub", bundle: .module)
            }
            .accessibilityElement(children: .combine)
        case .savedToGitHub:
            Label(String(localized: "Saved to GitHub", bundle: .module), systemImage: "checkmark")
        case .cloudFailure(let message):
            Label(
                String(localized: "Saved on this iPhone. Couldn't save to GitHub.", bundle: .module),
                systemImage: "exclamationmark.circle"
            )
            Text(verbatim: message)
            retryButton
        case .localFailure(let message):
            Label(
                String(localized: "Couldn't save on this iPhone. Keep the editor open.", bundle: .module),
                systemImage: "exclamationmark.triangle"
            )
            Text(verbatim: message)
            retryButton
        case .remoteChange:
            Label(String(localized: "This note changed elsewhere.", bundle: .module), systemImage: "exclamationmark.circle")
            if let review = actions.reviewChanges {
                Button(String(localized: "Review changes", bundle: .module), action: review)
                    .frame(minHeight: 44)
            }
        case .reconnectRequired:
            Label(
                String(localized: "Saved on this iPhone. Reconnect GitHub to publish changes.", bundle: .module),
                systemImage: "person.crop.circle"
            )
            if let reconnect = actions.reconnect {
                Button(String(localized: "Reconnect GitHub", bundle: .module), action: reconnect)
                    .frame(minHeight: 44)
            }
        case .creationUncertain:
            Label(
                String(localized: "Saved on this iPhone. GitHub may already have created this gist. Check GitHub before trying again.", bundle: .module),
                systemImage: "exclamationmark.circle"
            )
            if let open = actions.openInGitHub {
                Button(String(localized: "Check GitHub", bundle: .module), action: open)
                    .frame(minHeight: 44)
            }
        case .publicationUncertain:
            Label(
                String(localized: "Saved on this iPhone. GitHub couldn't confirm the last save.", bundle: .module),
                systemImage: "exclamationmark.circle"
            )
            if let retry = actions.retry {
                Button(String(localized: "Check save status", bundle: .module), action: retry)
                    .frame(minHeight: 44)
            }
        case .publicationBlocked(let message):
            Label(String(localized: "Saved on this iPhone. Publishing is unavailable.", bundle: .module), systemImage: "exclamationmark.shield")
            Text(verbatim: message)
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if let retry = actions.retry {
            Button(String(localized: "Retry", bundle: .module), action: retry)
                .frame(minHeight: 44)
        }
    }

    private var files: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(document.files) { file in
                        Button {
                            if file.id == document.selectedFileID {
                                showingFiles = false
                            } else {
                                actions.selectFile?(file.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(verbatim: file.filename).foregroundStyle(.primary)
                                Spacer()
                                if file.id == document.selectedFileID {
                                    Image(systemName: "checkmark").foregroundStyle(InterfaceTheme.accent)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(actions.selectFile == nil && file.id != document.selectedFileID)
                        .accessibilityAddTraits(file.id == document.selectedFileID ? .isSelected : [])
                    }
                }
                if document.access.canEdit && (actions.renameFile != nil || actions.addFile != nil) {
                    Section {
                        if let rename = actions.renameFile {
                            Button(String(localized: "Rename File", bundle: .module), systemImage: "pencil") {
                                pendingFileAction = rename
                                showingFiles = false
                            }
                        }
                        if let add = actions.addFile {
                            Button(String(localized: "Add File", bundle: .module), systemImage: "doc.badge.plus") {
                                pendingFileAction = add
                                showingFiles = false
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Files in this gist", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { showingFiles = false }
                }
            }
        }
    }

}
#endif
