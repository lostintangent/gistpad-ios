#if os(iOS)
import SwiftUI

private struct LibrarySearchOwnerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var librarySearchManagedByContainer: Bool {
        get { self[LibrarySearchOwnerKey.self] }
        set { self[LibrarySearchOwnerKey.self] = newValue }
    }
}

private struct LibrarySearchModifier: ViewModifier {
    @Bindable var model: LibraryModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.loadState == .signedOut {
            content.environment(\.librarySearchManagedByContainer, true)
        } else {
            content
                .searchable(text: $model.query, placement: .sidebar, prompt: Text("Search notes", bundle: .module))
                .searchToolbarBehavior(.minimize)
                .environment(\.librarySearchManagedByContainer, true)
        }
    }
}

extension View {
    public func librarySearch(model: LibraryModel) -> some View {
        modifier(LibrarySearchModifier(model: model))
    }
}

public struct LibraryActions {
    public var refresh: @MainActor () async -> Void
    public var create: @MainActor () -> Void
    public var today: @MainActor () -> Void
    public var select: (@MainActor (String) -> Void)?
    public var reconnect: (@MainActor () -> Void)?
    public var account: (@MainActor () -> Void)?
    public var togglePin: (@MainActor (String) -> Void)?
    public var toggleArchive: (@MainActor (String) -> Void)?

    public init(
        refresh: @escaping @MainActor () async -> Void,
        create: @escaping @MainActor () -> Void,
        today: @escaping @MainActor () -> Void
    ) {
        self.refresh = refresh
        self.create = create
        self.today = today
    }
}

public struct NotebookArtwork: View {
    public init() {}

    public var body: some View {
        Image("Notebook", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}

public struct LibraryView: View {
    private enum Selection: Hashable {
        case today
        case note(String)
    }

    struct FeaturedGrid<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 12)], alignment: .leading, spacing: 12) {
                content
            }
        }
    }

    struct NoteRowContent: View {
        let note: LibraryNote
        let tags: [LibraryTag]
        var showsPin = true
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: note.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if note.isPinned && showsPin {
                        Image(systemName: "pin.fill")
                            .font(.subheadline)
                            .foregroundStyle(InterfaceTheme.accent)
                            .accessibilityLabel(Text("Pinned", bundle: .module))
                    }
                }
                if let excerpt = note.excerpt, !excerpt.isEmpty {
                    Text(verbatim: excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                NoteRowMetadata(note: note, tags: tags)
                if let filename = note.filename, filename != note.title {
                    Text(verbatim: filename)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let progress = note.progress {
                    TaskProgressLabel(progress: progress)
                }
                if note.isOverdue {
                    Label(String(localized: "Unfinished tasks", bundle: .module), systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
    }

    struct NoteRowMetadata: View {
        let note: LibraryNote
        let tags: [LibraryTag]
        @Environment(\.layoutDirection) private var layoutDirection

        var body: some View {
            MetadataFlowLayout(layoutDirection: layoutDirection) {
                if !note.isOwned, let owner = note.owner {
                    Text(verbatim: "@\(owner)")
                }
                Text(note.updatedAt, format: .relative(presentation: .named))
                ForEach(tags.prefix(2)) { TagLabel(tag: $0) }
                if tags.count > 2 {
                    TagLabels.TagOverflowLabel(count: tags.count - 2)
                        .accessibilityLabel(Text(
                            "Tags: \(tags.dropFirst(2).map(\.name).joined(separator: ", "))",
                            bundle: .module
                        ))
                }
                if let count = note.fileCount, count > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .accessibilityHidden(true)
                        Text("\(count) files", bundle: .module)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @Bindable private var model: LibraryModel
    private let actions: LibraryActions
    private let footer: Text?
    private let isTodaySelected: Bool
    private let sidebarOverride: Bool?
    @State private var showingTags = false
    @State private var tagQuery = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.librarySearchManagedByContainer) private var searchManagedByContainer

    public init(
        model: LibraryModel, actions: LibraryActions, footer: Text? = nil,
        isTodaySelected: Bool = false, isSidebar: Bool? = nil
    ) {
        self.model = model
        self.actions = actions
        self.footer = footer
        self.isTodaySelected = isTodaySelected
        sidebarOverride = isSidebar
    }

    public var body: some View {
        navigationList
            .navigationTitle(navigationTitle)
            .toolbarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            .refreshable { await actions.refresh() }
            .toolbar { libraryToolbar }
            .sheet(isPresented: $showingTags) { tagFilters }
            .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder
    private var navigationList: some View {
        if model.loadState == .signedOut {
            signedOutInvitation
        } else if searchManagedByContainer {
            adaptiveList
                .toolbarTitleMenu { collectionPicker }
        } else {
            adaptiveList
                .searchable(text: $model.query, prompt: Text("Search notes", bundle: .module))
                .searchToolbarBehavior(.minimize)
                .toolbarTitleMenu { collectionPicker }
        }
    }

    @ViewBuilder
    private var adaptiveList: some View {
        if isSidebar {
            libraryList.listStyle(.sidebar)
        } else {
            libraryList
                .listStyle(.insetGrouped)
                .listSectionSpacing(32)
        }
    }

    private var isSidebar: Bool { sidebarOverride ?? (horizontalSizeClass == .regular) }

    private var navigationTitle: String {
        if model.loadState == .signedOut { return "" }
        return model.collection == .gists ? String(localized: "Library", bundle: .module) : model.collection.title
    }

    private var libraryList: some View {
        List(selection: librarySelection) {
            status
            if model.loadState != .signedOut {
                if model.showsFeaturedNotes {
                    Section {
                        if isSidebar {
                            NavigationLink(value: Selection.today) {
                                Label(String(localized: "Today", bundle: .module), systemImage: "calendar")
                                    .font(.headline)
                                    .frame(minHeight: 44)
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .tag(Selection.today)
                            .listRowBackground(isTodaySelected ? InterfaceTheme.selection : nil)
                            .listRowSeparator(.hidden)
                            .accessibilityValue(Text(
                                model.today.date,
                                format: Date.FormatStyle(date: .complete, time: .omitted, timeZone: model.today.timeZone)
                            ))
                            .accessibilityIdentifier("library-today")
                        } else {
                            Button(action: actions.today) {
                                TodayFeature(summary: model.today)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("library-today")
                        }
                    }
                    .listSectionMargins(.top, 16)
                }
                if model.hasFilters {
                    searchScope
                }
                searchStatus
                if let open = model.openDocumentOutsideFilter {
                    Section {
                        noteRow(open)
                    } header: {
                        sectionHeading(String(localized: "Open document", bundle: .module))
                    }
                }
                if !model.featuredNotes.isEmpty {
                    Section {
                        pinnedNotes
                    } header: {
                        pinnedHeading
                    }
                }
                if !model.listedNotes.isEmpty {
                    Section {
                        ForEach(model.listedNotes) { noteRow($0) }
                    } header: {
                        sectionHeading(model.hasFilters ? String(localized: "Results", bundle: .module) : model.collection.title)
                    }
                    .listSectionSeparator(.hidden)
                }
                if model.matchingNotes.isEmpty && model.loadState != .loading && canShowEmptyState {
                    emptyState
                }
                if let footer {
                    Section {} footer: { footer }
                }
            }
        }
    }

    private var librarySelection: Binding<Selection?> {
        Binding(
            get: { isTodaySelected ? .today : model.selectedNoteID.map(Selection.note) },
            set: { selection in
                switch selection {
                case .today:
                    if !isTodaySelected { actions.today() }
                case .note(let id):
                    if let select = actions.select {
                        select(id)
                    } else {
                        model.selectedNoteID = id
                    }
                case nil:
                    model.selectedNoteID = nil
                }
            }
        )
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color(uiColor: .label))
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private var pinnedHeading: some View {
        sectionHeading(String(localized: "Pinned", bundle: .module))
    }

    @ViewBuilder
    private var pinnedNotes: some View {
        if !isSidebar, !dynamicTypeSize.isAccessibilitySize,
           model.featuredNotes.count > 1 {
            FeaturedGrid {
                ForEach(model.featuredNotes) { note in
                    Button {
                        librarySelection.wrappedValue = .note(note.id)
                    } label: {
                        featuredContent(note)
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(
                                model.selectedNoteID == note.id
                                    ? InterfaceTheme.selection : Color(uiColor: .secondarySystemGroupedBackground),
                                in: .rect(cornerRadius: 20)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selectedNoteID == note.id ? .isSelected : [])
                    .accessibilityIdentifier("library-featured-\(note.id)")
                    .contextMenu { rowActions(note) }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            ForEach(model.featuredNotes) { note in
                NavigationLink(value: Selection.note(note.id)) {
                    featuredContent(note)
                        .padding(.vertical, 16)
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityIdentifier("library-featured-\(note.id)")
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(model.selectedNoteID == note.id ? InterfaceTheme.selection : nil)
                .contextMenu { rowActions(note) }
            }
        }
    }

    private func featuredContent(_ note: LibraryNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: note.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            if let excerpt = note.excerpt, !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !model.tags(for: note).isEmpty {
                featuredTags(model.tags(for: note))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Pinned", bundle: .module))
    }

    private func featuredTags(_ tags: [LibraryTag]) -> some View {
        ViewThatFits(in: .horizontal) {
            TagLabels(tags: tags, limit: 2)
                .fixedSize(horizontal: true, vertical: false)
            TagLabels(tags: tags, limit: 1)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                if let tag = tags.first {
                    TagLabel(tag: tag).lineLimit(1)
                }
                if tags.count > 1 {
                    TagLabels.TagOverflowLabel(count: tags.count - 1)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tags: \(tags.map(\.name).joined(separator: ", "))", bundle: .module))
    }

    private var searchScope: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.collection.title, systemImage: model.collection.symbol)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button(String(localized: "Clear", bundle: .module)) { model.clearFilters() }
                        .font(.subheadline)
                }
                if !model.selectedTagIDs.isEmpty {
                    TagLabels(
                        tags: model.snapshot.tags.filter { model.selectedTagIDs.contains($0.id) },
                        isSelected: true
                    )
                }
                if model.collection != .gists {
                    Button(String(localized: "Search All Notes", bundle: .module)) {
                        model.collection = .gists
                    }
                    .font(.subheadline)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text(
                "Search titles, filenames and tags. Available cached text is included. All selected tags must match.",
                bundle: .module
            )
        }
    }

    private var canShowEmptyState: Bool {
        switch model.loadState {
        case .ready: break
        case .offline:
            guard !model.snapshot.notes.isEmpty else { return false }
        case .loading, .failed, .reconnectRequired, .signedOut: return false
        }
        return switch model.searchState {
        case .inactive, .results: true
        case .searching, .failed: false
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        switch model.searchState {
        case .inactive:
            EmptyView()
        case .searching:
            Section {
                ProgressView(String(localized: "Searching notes", bundle: .module))
            }
        case .failed(let message):
            Section {
                Label(String(localized: "Search needs attention", bundle: .module), systemImage: "exclamationmark.circle")
                Text(verbatim: message).foregroundStyle(.primary)
            }
        case .results(_, let coverage):
            if !coverage.isComplete {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Content from \(coverage.documentsWithCachedContent) of \(coverage.totalDocuments) notes is available to search.", bundle: .module)
                        if coverage.incompleteGistCount > 0 {
                            Text("\(coverage.incompleteGistCount) gists have incomplete file lists.", bundle: .module)
                        }
                        if coverage.staleResultCount > 0 {
                            Text("\(coverage.staleResultCount) results have older cached content.", bundle: .module)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.loadState {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Updating from GitHub", bundle: .module)
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
        case .offline:
            Section {
                Label {
                    Text("Offline. Showing notes on this iPhone.", bundle: .module)
                } icon: { Image(systemName: "wifi.slash") }
                .font(.subheadline)
                if model.snapshot.notes.isEmpty {
                    Text("No notes are available offline yet. Connect to GitHub to load your notebook.", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                Label(String(localized: "Couldn't update from GitHub.", bundle: .module), systemImage: "exclamationmark.circle")
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Button(String(localized: "Retry", bundle: .module)) {
                    Task { await actions.refresh() }
                }
            }
        case .reconnectRequired(let message):
            Section {
                Label(String(localized: "Reconnect GitHub", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let reconnect = actions.reconnect {
                    Button(String(localized: "Continue with GitHub", bundle: .module), action: reconnect)
                }
            }
        case .signedOut, .ready:
            EmptyView()
        }
    }

    private var signedOutInvitation: some View {
        ContentUnavailableView {
            NotebookArtwork()
            Text("Your notebook, on GitHub", bundle: .module)
                .font(.title2.weight(.semibold))
        } description: {
            Text("Markdown notes, backed by your GitHub gists.", bundle: .module)
        } actions: {
            if let reconnect = actions.reconnect {
                Button(String(localized: "Continue with GitHub", bundle: .module), action: reconnect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .tint(InterfaceTheme.accent)
                    .accessibilityIdentifier("library-sign-in")
            }
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                if !model.hasFilters, model.collection == .gists {
                    NotebookArtwork()
                    Text(verbatim: emptyTitle)
                        .font(.title2.weight(.semibold))
                } else {
                    Label(
                        model.hasFilters
                            ? String(localized: "No matching notes", bundle: .module)
                            : emptyTitle,
                        systemImage: model.hasFilters ? "magnifyingglass" : model.collection.symbol
                    )
                }
            } description: {
                if model.hasFilters {
                    Text("Try another search or clear your filters. Notes without cached text can still match by title, filename or tag.", bundle: .module)
                } else {
                    Text(verbatim: emptyDescription)
                }
            } actions: {
                if model.hasFilters {
                    Button(String(localized: "Clear filters", bundle: .module)) { model.clearFilters() }
                } else if model.collection == .gists {
                    Button(String(localized: "Create a note", bundle: .module), action: actions.create)
                        .buttonStyle(.borderedProminent)
                } else if model.collection == .dailyNotes {
                    Button(String(localized: "Start today's note", bundle: .module), action: actions.today)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private var emptyTitle: String {
        switch model.collection {
        case .gists: String(localized: "A notebook of your own", bundle: .module)
        case .dailyNotes: String(localized: "A fresh day", bundle: .module)
        case .starred: String(localized: "Keep a useful discovery", bundle: .module)
        case .archive: String(localized: "Nothing in the archive", bundle: .module)
        }
    }

    private var emptyDescription: String {
        switch model.collection {
        case .gists: String(localized: "A thought, a list, a little thing worth keeping. Start with your first note.", bundle: .module)
        case .dailyNotes: String(localized: "Your daily notes will gather here. Begin with today.", bundle: .module)
        case .starred: String(localized: "Star a gist on GitHub to find it here.", bundle: .module)
        case .archive: String(localized: "Finished notes stay here when you archive them. You can bring them back anytime.", bundle: .module)
        }
    }

    private func noteRow(_ note: LibraryNote, showsPin: Bool = true) -> some View {
        NavigationLink(value: Selection.note(note.id)) {
            NoteRowContent(note: note, tags: model.tags(for: note), showsPin: showsPin)
        }
        .accessibilityValue(note.isPinned ? Text("Pinned", bundle: .module) : Text(""))
        .accessibilityIdentifier("library-note-\(note.id)")
        .navigationLinkIndicatorVisibility(.hidden)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.visible)
        .listRowBackground(model.selectedNoteID == note.id ? InterfaceTheme.selection : nil)
        .contextMenu { rowActions(note) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if note.isOwned, let archive = actions.toggleArchive {
                Button {
                    archive(note.id)
                } label: {
                    Label(
                        note.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                        systemImage: "archivebox"
                    )
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if note.isOwned, let pin = actions.togglePin {
                Button {
                    pin(note.id)
                } label: {
                    Label(
                        note.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                        systemImage: note.isPinned ? "pin.slash" : "pin"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ note: LibraryNote) -> some View {
        if note.isOwned, let pin = actions.togglePin {
            Button(
                note.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                systemImage: note.isPinned ? "pin.slash" : "pin"
            ) { pin(note.id) }
        }
        if note.isOwned, let archive = actions.toggleArchive {
            Button(
                note.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                systemImage: "archivebox"
            ) { archive(note.id) }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if model.loadState != .signedOut {
            if isSidebar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "New note", bundle: .module), systemImage: "square.and.pencil", action: actions.create)
                    .accessibilityIdentifier("library-create")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingTags = true
                } label: {
                    Label(
                        model.selectedTagIDs.isEmpty
                            ? String(localized: "Filter by tags", bundle: .module)
                            : String(localized: "Tag filters applied", bundle: .module),
                        systemImage: model.selectedTagIDs.isEmpty ? "tag" : "tag.fill"
                    )
                }
                .disabled(model.snapshot.tags.isEmpty)
            }
        }
        if let account = actions.account {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Settings", bundle: .module), systemImage: "gearshape", action: account)
            }
        }
    }

    private var collectionPicker: some View {
        Picker(String(localized: "Collection", bundle: .module), selection: $model.collection) {
            ForEach(LibraryCollection.allCases) { collection in
                Label(
                    collection == .gists ? String(localized: "All Notes", bundle: .module) : collection.title,
                    systemImage: collection.symbol
                )
                .tag(collection)
            }
        }
        .accessibilityIdentifier("library-collection")
    }

    private var tagFilters: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matchingTags) { tag in
                        Button {
                            if model.selectedTagIDs.contains(tag.id) {
                                model.selectedTagIDs.remove(tag.id)
                            } else {
                                model.selectedTagIDs.insert(tag.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                TagSwatch(hex: tag.colorHex)
                                Text(verbatim: tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if model.selectedTagIDs.contains(tag.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(InterfaceTheme.accent)
                                        .transition(.opacity)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(model.selectedTagIDs.contains(tag.id) ? .isSelected : [])
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.selectedTagIDs.contains(tag.id))
                    }
                } footer: {
                    Text("All selected tags must match. Tags apply to the whole gist.", bundle: .module)
                }
                if !model.selectedTagIDs.isEmpty {
                    Button(String(localized: "Clear tag filters", bundle: .module)) {
                        model.selectedTagIDs = []
                    }
                }
            }
            .navigationTitle(Text("Filter by tags", bundle: .module))
            .searchable(text: $tagQuery, prompt: Text("Search tags", bundle: .module))
            .overlay {
                if matchingTags.isEmpty {
                    ContentUnavailableView.search(text: tagQuery)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { showingTags = false }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var matchingTags: [LibraryTag] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.snapshot.tags.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
