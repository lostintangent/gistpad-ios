#if os(iOS)
import GistPadAppearance
import GistPadSync
import SwiftUI

public struct NoteScreen<Source: View, Preview: View>: View {
    private let document: NoteChrome
    @Binding private var mode: NoteMode
    private let saveState: PublishState
    private let actions: NoteActions
    private let source: Source
    private let preview: Preview
    private let isFocused: Bool
    private let allowsSplit: Bool
    private let isSidebarHidden: Bool
    private let areCommentsPresented: Bool
    @State private var confirmingDeletion = false
    // Match the native toolbar's settled segment size on its first layout.
    @ScaledMetric(relativeTo: .body) private var minimumModeSegmentWidth = 48

    private var showingSplit: Bool { document.access.canEdit && (isFocused || (allowsSplit && mode == .split)) }
    private var showingSource: Bool { document.access.canEdit && (showingSplit || mode != .reading) }
    private var paneLayout: AnyLayout {
        showingSplit ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(ZStackLayout())
    }
    private var showsFiles: Bool {
        document.files.count > 1 || (document.access.canEdit && (actions.addFile != nil || actions.renameFile != nil))
    }

    public init(
        document: NoteChrome, mode: Binding<NoteMode>, saveState: PublishState,
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
        if document.access.canEdit, saveState.showsPublish(isAutoSaveEnabled: document.isAutoSaveEnabled) {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Publish", bundle: .module), systemImage: "arrow.up.doc", action: actions.save)
                    .disabled(!saveState.canPublish)
                    .accessibilityIdentifier("note-publish")
            }
        }
        if document.access.canEdit, let needsYou {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "GitHub needs attention", bundle: .module), systemImage: "exclamationmark", action: needsYou)
                    .accessibilityIdentifier("note-needs-you")
            }
        }
    }

    /// A conflict opens the diff, and a lost connection reconnects GitHub.
    private var needsYou: (() -> Void)? {
        switch saveState {
        case .conflict: actions.reviewChanges
        case .reconnect: actions.reconnect
        default: nil
        }
    }

    private var modePicker: some View {
        Picker(
            String(localized: "View", bundle: .module),
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
                            String(localized: "Rename Gist…", bundle: .module),
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
                Label(String(localized: "More", bundle: .module), systemImage: "ellipsis")
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
