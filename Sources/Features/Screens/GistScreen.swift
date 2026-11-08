#if os(iOS)
import Accent
import Store
import SwiftUI

public struct GistScreen<Source: View, Preview: View>: View {
    private let gist: GistDetails
    @Binding private var mode: FileMode
    private let status: PublishStatus
    private let actions: GistActions
    private let source: Source
    private let preview: Preview
    private let allowsSplit: Bool
    private let areCommentsPresented: Bool
    @State private var confirmingDeletion = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    // Match the native toolbar's settled segment size on its first layout.
    @ScaledMetric(relativeTo: .body) private var minimumModeSegmentWidth = 48

    private var showingSplit: Bool { gist.access.canEdit && allowsSplit && mode == .split }
    private var showingSource: Bool { gist.access.canEdit && (showingSplit || mode != .preview) }
    private var paneLayout: AnyLayout {
        showingSplit ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(ZStackLayout())
    }
    private var title: String { gist.displayTitle(now: .now, locale: locale, calendar: calendar) }
    private var switchesFiles: Bool { gist.files.count > 1 && actions.selectFile != nil }
    private var showsFiles: Bool {
        switchesFiles || (gist.access.canEdit && (actions.addFile != nil || actions.renameFile != nil))
    }

    public init(
        gist: GistDetails, mode: Binding<FileMode>, status: PublishStatus,
        actions: GistActions = .init(),
        allowsSplit: Bool = false,
        areCommentsPresented: Bool = false,
        @ViewBuilder source: () -> Source, @ViewBuilder preview: () -> Preview
    ) {
        self.gist = gist
        self._mode = mode
        self.status = status
        self.actions = gist.isDailyNote ? actions.dailyNote : actions
        self.allowsSplit = allowsSplit
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
        .gistTitle(
            title, filename: gist.headerFilename, pinnedWidth: pickerWidth, buttons: trailingButtons,
            menu: showsFiles ? fileChoices : nil)
        .toolbar {
            primaryToolbar
            secondaryToolbar
        }
    }

    /// The room the mode picker takes beside the title.
    private var pickerWidth: CGFloat {
        gist.access.canEdit ? minimumModeSegmentWidth * CGFloat(allowsSplit ? 3 : 2) + 8 : 0
    }

    /// Publish, GitHub needs attention, Comments and More.
    private var trailingButtons: Int {
        let publishes = gist.access.canEdit && status.showsPublish(isAutoSaveEnabled: gist.isAutoSaveEnabled)
        return [publishes, gist.access.canEdit && needsYou != nil, actions.comments != nil, true]
            .filter(\.self).count
    }

    @ToolbarContentBuilder
    private var primaryToolbar: some ToolbarContent {
        if gist.access.canEdit {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                modePicker
                    .frame(minWidth: minimumModeSegmentWidth * CGFloat(allowsSplit ? 3 : 2))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if gist.access.canEdit, status.showsPublish(isAutoSaveEnabled: gist.isAutoSaveEnabled) {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Publish", bundle: .module), systemImage: "arrow.up.doc", action: actions.save)
                    .disabled(!status.canPublish)
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
        switch status {
        case .conflict: actions.reviewChanges
        case .failed(.reconnect): actions.reconnect
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
                    ToolbarBadgeLabel(
                        title: String(localized: "Comments", bundle: .module), systemImage: "text.bubble",
                        count: gist.commentCount, isFilled: areCommentsPresented)
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .symbolVariant(.none)
                .tint(.primary)
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
                        // The share sheet can't present over the Comments sheet on iPhone.
                        if !(areCommentsPresented && horizontalSizeClass == .compact) {
                            ShareLink(
                                item: url,
                                preview: SharePreview(title, icon: Image("Artwork", bundle: .module))
                            )
                        }
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
                    Button(
                        String(localized: "Intelligence…", bundle: .module),
                        systemImage: "sparkles", action: actions.intelligence
                    )
                    .accessibilityIdentifier("note-intelligence")
                    if gist.access.canEdit {
                        Button(String(localized: "Find and Replace", bundle: .module), systemImage: "text.magnifyingglass", action: actions.find)
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
                        Button(
                            gist.isDailyNote
                                ? String(localized: "Delete Daily Note…", bundle: .module)
                                : String(localized: "Delete Gist…", bundle: .module),
                            systemImage: "trash", role: .destructive
                        ) {
                            confirmingDeletion = true
                        }
                    }
                }
            } label: {
                Label(String(localized: "More", bundle: .module), systemImage: "ellipsis")
            }
            .accessibilityIdentifier("note-actions")
            .deletionConfirmation(
                title: title, isDailyNote: gist.isDailyNote, isPresented: $confirmingDeletion
            ) {
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
        if switchesFiles, let selectFile = actions.selectFile {
            Picker(
                String(localized: "Files", bundle: .module),
                selection: Binding(
                    get: { gist.selectedFileID },
                    set: { if $0 != gist.selectedFileID { selectFile($0) } })
            ) {
                ForEach(gist.files) { Text(verbatim: $0.filename).tag($0.id) }
            }
            .pickerStyle(.inline)
        }
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
#endif
