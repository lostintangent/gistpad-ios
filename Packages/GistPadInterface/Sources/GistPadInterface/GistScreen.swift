#if os(iOS)
import GistPadAccent
import GistPadSync
import SwiftUI

public struct GistScreen<Source: View, Preview: View>: View {
    private let gist: GistDetails
    @Binding private var mode: FileMode
    private let saveState: PublishState
    private let actions: GistActions
    private let source: Source
    private let preview: Preview
    private let isFocused: Bool
    private let allowsSplit: Bool
    private let isSidebarHidden: Bool
    private let areCommentsPresented: Bool
    @State private var confirmingDeletion = false
    // Match the native toolbar's settled segment size on its first layout.
    @ScaledMetric(relativeTo: .body) private var minimumModeSegmentWidth = 48

    private var showingSplit: Bool { gist.access.canEdit && (isFocused || (allowsSplit && mode == .split)) }
    private var showingSource: Bool { gist.access.canEdit && (showingSplit || mode != .preview) }
    private var paneLayout: AnyLayout {
        showingSplit ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(ZStackLayout())
    }
    private var showsFiles: Bool {
        gist.files.count > 1 || (gist.access.canEdit && (actions.addFile != nil || actions.renameFile != nil))
    }

    public init(
        gist: GistDetails, mode: Binding<FileMode>, saveState: PublishState,
        actions: GistActions = .init(), isFocused: Bool = false,
        allowsSplit: Bool = false, isSidebarHidden: Bool = false,
        areCommentsPresented: Bool = false,
        @ViewBuilder source: () -> Source, @ViewBuilder preview: () -> Preview
    ) {
        self.gist = gist
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
                .environment(\.isPaneVisible, showingSource)
            preview
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .opacity(!showingSource || showingSplit ? 1 : 0)
                .allowsHitTesting(!showingSource || showingSplit)
                .accessibilityHidden(showingSource && !showingSplit)
                .environment(\.isPaneVisible, !showingSource || showingSplit)
        }
        .overlay {
            if showingSplit {
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(gist.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(gist.headerFilename ?? "")
        .modifier(FileMenu(isEnabled: gist.files.count > 1) { fileChoices })
        .toolbar {
            primaryToolbar
            secondaryToolbar
        }
    }

    @ToolbarContentBuilder
    private var primaryToolbar: some ToolbarContent {
        if gist.access.canEdit, !isFocused {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                modePicker
                    .frame(minWidth: minimumModeSegmentWidth * CGFloat(allowsSplit ? 3 : 2))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if gist.access.canEdit, saveState.showsPublish(isAutoSaveEnabled: gist.isAutoSaveEnabled) {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Publish", bundle: .module), systemImage: "arrow.up.doc", action: actions.save)
                    .disabled(!saveState.canPublish)
                    .accessibilityIdentifier("note-publish")
            }
        }
        if gist.access.canEdit, let needsYou {
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
                get: { mode == .split && !allowsSplit ? .edit : mode },
                set: { mode = $0 }
            )
        ) {
            Label(String(localized: "Edit", bundle: .module), systemImage: "square.and.pencil").tag(FileMode.edit)
            if allowsSplit {
                Label(String(localized: "Split", bundle: .module), systemImage: "rectangle.split.2x1").tag(FileMode.split)
            }
            Label(String(localized: "Preview", bundle: .module), systemImage: "eye").tag(FileMode.preview)
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
                            gist.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                            systemImage: gist.isPinned ? "pin.fill" : "pin", action: pin
                        )
                    }
                    if let star = actions.toggleStar {
                        Button(
                            gist.isStarred ? String(localized: "Unstar", bundle: .module) : String(localized: "Star", bundle: .module),
                            systemImage: gist.isStarred ? "star.fill" : "star", action: star
                        )
                    }
                    if let url = gist.shareURL {
                        ShareLink(item: url, preview: SharePreview(gist.title))
                        Button(String(localized: "Copy Link", bundle: .module), systemImage: "link") {
                            UIPasteboard.general.url = url
                            AccessibilityNotification.Announcement(
                                String(localized: "Link copied", bundle: .module)
                            ).post()
                        }
                    }
                }
                .controlGroupStyle(.compactMenu)
                Section {
                    if let rename = actions.rename, gist.access.canEdit {
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
                    if gist.access.canEdit {
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
                            gist.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                            systemImage: "archivebox", action: archive
                        )
                    }
                }
                if actions.delete != nil, gist.access.canEdit {
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
            .deletionConfirmation(title: gist.title, isPresented: $confirmingDeletion) {
                actions.delete?()
            }
        }
    }

    private var commentsLabel: String {
        let title = String(localized: "Comments", bundle: .module)
        guard let count = gist.commentCount else { return title }
        return title + ", " + String(localized: "\(count) comments", bundle: .module)
    }

    @ViewBuilder
    private var fileChoices: some View {
        Picker(
            String(localized: "Files", bundle: .module),
            selection: Binding(
                get: { gist.selectedFileID },
                set: { if $0 != gist.selectedFileID { actions.selectFile?($0) } })
        ) {
            ForEach(gist.files) { Text(verbatim: $0.filename).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(actions.selectFile == nil)
        if gist.access.canEdit && (actions.renameFile != nil || actions.addFile != nil) {
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

private struct FileMenu<Items: View>: ViewModifier {
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
