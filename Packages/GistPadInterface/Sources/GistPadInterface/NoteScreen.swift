#if os(iOS)
import GistPadAppearance
import SwiftUI

public struct NoteScreen<Source: View, Preview: View>: View {
    private let document: NoteChrome
    @Binding private var mode: NoteMode
    private let saveState: NoteSaveState
    private let actions: NoteActions
    private let source: Source
    private let preview: Preview
    private let isFocused: Bool
    private let allowsSplit: Bool
    private let isSidebarHidden: Bool
    private let areCommentsPresented: Bool
    @State private var showingOfflineExplanation = false
    @State private var confirmingDeletion = false
    @State private var saveDetails: String?
    // Match the native toolbar's settled segment size on its first layout.
    @ScaledMetric(relativeTo: .body) private var minimumModeSegmentWidth = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var showingSplit: Bool { document.access.canEdit && (isFocused || (allowsSplit && mode == .split)) }
    private var showingSource: Bool { document.access.canEdit && (showingSplit || mode != .reading) }
    private var paneLayout: AnyLayout {
        showingSplit ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(ZStackLayout())
    }
    private var showsFiles: Bool {
        document.files.count > 1 || (document.access.canEdit && (actions.addFile != nil || actions.renameFile != nil))
    }

    public init(
        document: NoteChrome, mode: Binding<NoteMode>, saveState: NoteSaveState,
        actions: NoteActions = .init(), isFocused: Bool = false,
        allowsSplit: Bool = false, isSidebarHidden: Bool = false,
        areCommentsPresented: Bool = false,
        @ViewBuilder source: () -> Source, @ViewBuilder preview: () -> Preview
    ) {
        self.document = document
        self._mode = mode
        self.saveState = saveState
        self.actions = actions
        self.isFocused = isFocused
        self.allowsSplit = allowsSplit
        self.isSidebarHidden = isSidebarHidden
        self.areCommentsPresented = areCommentsPresented
        self.source = source()
        self.preview = preview()
    }
    public var body: some View {
        paneLayout {
            source
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .opacity(showingSource ? 1 : 0)
                .allowsHitTesting(showingSource)
                .accessibilityHidden(!showingSource)
                .environment(\.isNotebookPaneVisible, showingSource)
            preview
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .opacity(!showingSource || showingSplit ? 1 : 0)
                .allowsHitTesting(!showingSource || showingSplit)
                .accessibilityHidden(showingSource && !showingSplit)
                .environment(\.isNotebookPaneVisible, !showingSource || showingSplit)
        }
        .overlay {
            if showingSplit {
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(document.headerFilename ?? "")
        .modifier(NoteTitleMenu(isEnabled: document.files.count > 1) { fileChoices })
        .toolbar {
            primaryToolbar
            secondaryToolbar
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if issue != nil {
                status
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .alert(String(localized: "Offline changes", bundle: .module), isPresented: $showingOfflineExplanation) {
            Button(String(localized: "Retry", bundle: .module), action: actions.retry)
            Button(String(localized: "Close", bundle: .module), role: .cancel) {}
        } message: {
            Text("Changes are saved on this iPhone but haven't synced to GitHub. Reconnect, then try saving again.", bundle: .module)
        }
        .alert(
            String(localized: "Save details", bundle: .module),
            isPresented: Binding(get: { saveDetails != nil }, set: { if !$0 { saveDetails = nil } })
        ) {
            if saveState == .creationUncertain {
                if let publish = actions.publishAsNew {
                    Button(String(localized: "Publish as New Note…", bundle: .module)) {
                        saveDetails = nil
                        publish()
                    }
                }
                if let discard = actions.discardLocalCopy {
                    Button(String(localized: "Discard This Copy…", bundle: .module), role: .destructive) {
                        saveDetails = nil
                        discard()
                    }
                }
            }
            Button(String(localized: "Close", bundle: .module), role: .cancel) { saveDetails = nil }
        } message: {
            Text(verbatim: saveDetails ?? "")
        }
    }

    @ToolbarContentBuilder
    private var primaryToolbar: some ToolbarContent {
        if document.access.canEdit, !isFocused {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                modePicker
                    .frame(minWidth: minimumModeSegmentWidth * CGFloat(allowsSplit ? 3 : 2))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if document.access.canEdit,
           saveState.showsManualSave(isAutoSaveEnabled: document.isAutoSaveEnabled) {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Save to GitHub", bundle: .module), systemImage: "arrow.up.doc", action: actions.save)
                    .disabled(!saveState.canPublish)
                    .accessibilityIdentifier("note-save")
            }
        }
        if document.access.canEdit, saveState == .offline {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingOfflineExplanation = true
                } label: {
                    Label(String(localized: "Offline changes haven't synced", bundle: .module), systemImage: "icloud.slash")
                }
                .accessibilityIdentifier("note-offline")
            }
        }
    }

    private var modePicker: some View {
        Picker(
            String(localized: "Note mode", bundle: .module),
            selection: Binding(
                get: { mode == .split && !allowsSplit ? .source : mode },
                set: { mode = $0 }
            )
        ) {
            Label(String(localized: "Edit", bundle: .module), systemImage: "square.and.pencil").tag(NoteMode.source)
            if allowsSplit {
                Label(String(localized: "Split", bundle: .module), systemImage: "rectangle.split.2x1").tag(NoteMode.split)
            }
            Label(String(localized: "Preview", bundle: .module), systemImage: "eye").tag(NoteMode.reading)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("note-toggle-mode")
    }

    @ToolbarContentBuilder
    private var secondaryToolbar: some ToolbarContent {
        if let comments = actions.comments {
            ToolbarItem(placement: .primaryAction) {
                Toggle(
                    isOn: Binding(
                        get: { areCommentsPresented },
                        set: { _ in comments() })
                ) {
                    Label(String(localized: "Comments", bundle: .module), systemImage: "text.bubble")
                }
                .toggleStyle(.button)
                .symbolVariant(.none)
                .badge(document.commentCount ?? 0)
                .accessibilityLabel(commentsLabel)
                .accessibilityAddTraits(areCommentsPresented ? .isSelected : [])
                .accessibilityIdentifier("note-comments")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ControlGroup {
                    if let pin = actions.togglePin {
                        Button(
                            document.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                            systemImage: document.isPinned ? "pin.fill" : "pin", action: pin
                        )
                    }
                    if let star = actions.toggleStar {
                        Button(
                            document.isStarred ? String(localized: "Unstar", bundle: .module) : String(localized: "Star", bundle: .module),
                            systemImage: document.isStarred ? "star.fill" : "star", action: star
                        )
                    }
                    Button(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up", action: actions.share)
                    Button(String(localized: "Copy Link", bundle: .module), systemImage: "link", action: actions.copyLink)
                }
                .controlGroupStyle(.compactMenu)
                Section {
                    if let rename = actions.rename, document.access.canEdit {
                        Button(
                            String(localized: "Rename Note…", bundle: .module),
                            systemImage: "pencil", action: rename
                        )
                        .accessibilityIdentifier("note-rename")
                    }
                    if let tags = actions.tags {
                        Button(String(localized: "Tags", bundle: .module), systemImage: "tag", action: tags)
                    }
                    if showsFiles {
                        Menu {
                            fileChoices
                        } label: {
                            Label(String(localized: "Files", bundle: .module), systemImage: "doc.on.doc")
                        }
                    }
                    Button(
                        String(localized: "Intelligence…", bundle: .module),
                        systemImage: "sparkles", action: actions.intelligence
                    )
                    .accessibilityIdentifier("note-intelligence")
                    if document.access.canEdit {
                        Button(String(localized: "Find and Replace", bundle: .module), systemImage: "text.magnifyingglass", action: actions.find)
                        Button(
                            isSidebarHidden ? String(localized: "Show Library", bundle: .module) : String(localized: "Hide Library", bundle: .module),
                            systemImage: "sidebar.left", action: actions.focus
                        )
                    }
                }
                if let open = actions.openInGitHub {
                    Section {
                        Button(String(localized: "Open in GitHub", bundle: .module), systemImage: "arrow.up.right", action: open)
                    }
                }
                if let archive = actions.toggleArchive {
                    Section {
                        Button(
                            document.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                            systemImage: "archivebox", action: archive
                        )
                    }
                }
                if actions.delete != nil, document.access.canEdit {
                    Section {
                        Button(String(localized: "Delete Note…", bundle: .module), systemImage: "trash", role: .destructive) {
                            confirmingDeletion = true
                        }
                    }
                }
            } label: {
                Label(String(localized: "Note actions", bundle: .module), systemImage: "ellipsis")
            }
            .accessibilityIdentifier("note-actions")
            .deletionConfirmation(title: document.title, isPresented: $confirmingDeletion) {
                actions.delete?()
            }
        }
    }

    private var commentsLabel: String {
        let title = String(localized: "Comments", bundle: .module)
        guard let count = document.commentCount else { return title }
        return title + ", " + String(localized: "\(count) comments", bundle: .module)
    }

    private var status: some View {
        Group {
            if let issue {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(issue.title, systemImage: issue.symbol)
                            .accessibilityIdentifier("note-save-issue")
                        HStack(spacing: 16) { recoveryButton; detailsButton(issue.details) }
                    }
                } else {
                    HStack(spacing: 12) {
                        Label(issue.title, systemImage: issue.symbol)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("note-save-issue")
                        Spacer(minLength: 0)
                        recoveryButton
                        detailsButton(issue.details)
                    }
                }
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-save-state")
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: saveState)
    }

    private var issue: (title: String, symbol: String, details: String?)? {
        if document.access == .truncated {
            return (
                String(localized: "Incomplete note. Editing is unavailable.", bundle: .module), "exclamationmark.shield",
                String(localized: "GitHub returned an incomplete note. Editing is unavailable to protect the original.", bundle: .module)
            )
        }
        return saveState.issue
    }

    @ViewBuilder
    private var recoveryButton: some View {
        switch saveState {
        case .cloudFailure, .localFailure:
            Button(String(localized: "Retry", bundle: .module), action: actions.retry).frame(minHeight: 44)
                .accessibilityIdentifier("note-save-retry")
        case .remoteChange:
            Button(String(localized: "Review", bundle: .module), action: actions.reviewChanges).frame(minHeight: 44)
        case .reconnectRequired:
            Button(String(localized: "Reconnect", bundle: .module), action: actions.reconnect).frame(minHeight: 44)
        case .creationUncertain:
            if let open = actions.openInGitHub {
                Button(String(localized: "Check GitHub", bundle: .module), action: open).frame(minHeight: 44)
            }
        case .publicationUncertain:
            Button(String(localized: "Check Status", bundle: .module), action: actions.retry).frame(minHeight: 44)
        default:
            if document.access == .truncated, let open = actions.openInGitHub {
                Button(String(localized: "Open in GitHub", bundle: .module), action: open).frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder
    private func detailsButton(_ details: String?) -> some View {
        if let details, !details.isEmpty {
            Button {
                saveDetails = details
            } label: {
                Label(String(localized: "Details", bundle: .module), systemImage: "info.circle")
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("note-save-details")
        }
    }

    @ViewBuilder
    private var fileChoices: some View {
        Picker(
            String(localized: "Files", bundle: .module),
            selection: Binding(
                get: { document.selectedFileID },
                set: { if $0 != document.selectedFileID { actions.selectFile?($0) } })
        ) {
            ForEach(document.files) { Text(verbatim: $0.filename).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(actions.selectFile == nil)
        if document.access.canEdit && (actions.renameFile != nil || actions.addFile != nil) {
            Section {
                if let rename = actions.renameFile {
                    Button(
                        String(localized: "Rename File…", bundle: .module),
                        systemImage: "pencil", action: rename
                    )
                    .accessibilityIdentifier("note-rename-file")
                }
                if let add = actions.addFile {
                    Button(String(localized: "Add File…", bundle: .module), systemImage: "doc.badge.plus", action: add)
                        .accessibilityIdentifier("note-add-file")
                }
            }
        }
    }
}

private struct NoteTitleMenu<Items: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder var items: () -> Items

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.toolbarTitleMenu(content: items)
        } else {
            content
        }
    }
}
#endif
