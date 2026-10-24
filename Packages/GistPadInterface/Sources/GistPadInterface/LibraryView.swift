#if os(iOS)
import SwiftUI

public struct LibraryActions {
    public var refresh: @MainActor () async -> Void
    public var create: @MainActor () -> Void
    public var today: @MainActor () -> Void
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

public struct LibraryView: View {
    @Bindable private var model: LibraryModel
    private let actions: LibraryActions
    private let footer: Text?
    @State private var showingTags = false
    @State private var tagQuery = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: LibraryModel, actions: LibraryActions, footer: Text? = nil) {
        self.model = model
        self.actions = actions
        self.footer = footer
    }

    public var body: some View {
        adaptiveList
            .listSectionMargins(.top, 8)
            .listSectionMargins(.bottom, 0)
            .environment(\.defaultMinListHeaderHeight, 0)
            .navigationTitle("GistPad")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            .searchable(text: $model.query, prompt: Text("Search notes", bundle: .module))
            .refreshable { await actions.refresh() }
            .toolbar { libraryToolbar }
            .sheet(isPresented: $showingTags) { tagFilters }
            .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder
    private var adaptiveList: some View {
        if horizontalSizeClass == .regular {
            libraryList.listStyle(.sidebar)
        } else {
            libraryList
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemBackground))
        }
    }

    private var libraryList: some View {
        List(selection: $model.selectedNoteID) {
            status
            if model.loadState != .signedOut {
                if model.collection == .gists && !model.hasFilters {
                    Section {
                        Button(action: actions.today) {
                            VStack(alignment: .leading, spacing: 12) {
                                TodayHeading(summary: model.today)
                                if let progress = model.today.progress {
                                    TaskProgressLabel(progress: progress)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("library-today")
                    }
                }
                if model.hasFilters {
                    Section {
                        Button {
                            model.clearFilters()
                        } label: {
                            Label(String(localized: "Clear filters", bundle: .module), systemImage: "line.3.horizontal.decrease")
                        }
                        if !model.selectedTagIDs.isEmpty {
                            TagLabels(
                                tags: model.snapshot.tags.filter { model.selectedTagIDs.contains($0.id) },
                                isSelected: true
                            )
                        }
                    } footer: {
                        if !model.selectedTagIDs.isEmpty {
                            Text("All selected tags must match.", bundle: .module)
                                .foregroundStyle(InterfaceTheme.text)
                        }
                    }
                }
                searchStatus
                if let open = model.openDocumentOutsideFilter {
                    Section {
                        noteRow(open)
                    } header: {
                        sectionHeading(String(localized: "Open document", bundle: .module))
                    }
                }
                if case .results = model.searchState {
                    if !model.matchingNotes.isEmpty {
                        Section {
                            ForEach(model.matchingNotes) { noteRow($0) }
                        } header: {
                            sectionHeading(model.collection.title)
                        }
                    }
                } else {
                    if !model.pinnedNotes.isEmpty {
                        Section {
                            ForEach(model.pinnedNotes) { noteRow($0, showsPin: false) }
                        } header: {
                            sectionHeading(String(localized: "Pinned", bundle: .module))
                        }
                    }
                    if !model.unpinnedNotes.isEmpty {
                        Section {
                            ForEach(model.unpinnedNotes) { noteRow($0) }
                        } header: {
                            sectionHeading(model.collection.title)
                        }
                    }
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

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(InterfaceTheme.text)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .accessibilityAddTraits(.isHeader)
    }

    private var canShowEmptyState: Bool {
        switch model.searchState {
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
        case .signedOut:
            Section {
                ContentUnavailableView {
                    Label(String(localized: "Your notebook, on GitHub", bundle: .module), systemImage: "book.closed")
                } description: {
                    Text("Reconnect your account to see your notes, tags and pins. Local drafts stay on this iPhone.", bundle: .module)
                } actions: {
                    if let reconnect = actions.reconnect {
                        Button(String(localized: "Continue with GitHub", bundle: .module), action: reconnect)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        case .ready:
            EmptyView()
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label(
                    model.hasFilters
                        ? String(localized: "No matching notes", bundle: .module)
                        : String(localized: "No notes here yet", bundle: .module),
                    systemImage: model.hasFilters ? "magnifyingglass" : model.collection.symbol
                )
            } description: {
                if model.hasFilters {
                    Text("Try another title or clear your tag filters.", bundle: .module)
                } else {
                    Text("Your notes will appear in this collection.", bundle: .module)
                }
            } actions: {
                if model.hasFilters {
                    Button(String(localized: "Clear filters", bundle: .module)) { model.clearFilters() }
                } else if model.collection == .gists {
                    Button(String(localized: "Create a note", bundle: .module), action: actions.create)
                } else if model.collection == .dailyNotes {
                    Button(String(localized: "Start today's note", bundle: .module), action: actions.today)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func noteRow(_ note: LibraryNote, showsPin: Bool = true) -> some View {
        NavigationLink(value: note.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: note.title)
                        .font(.headline)
                        .lineLimit(2)
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
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                if !model.tags(for: note).isEmpty {
                    TagLabels(tags: model.tags(for: note), limit: 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !note.isOwned, let owner = note.owner {
                        Text(verbatim: "@\(owner)")
                    }
                    Text(note.updatedAt, format: .relative(presentation: .named))
                    if let filename = note.filename, filename != note.title {
                        Text(verbatim: filename)
                    }
                    if let progress = note.progress {
                        TaskProgressLabel(progress: progress)
                    }
                    if note.isOverdue {
                        Label(String(localized: "Unfinished tasks", bundle: .module), systemImage: "clock")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityValue(note.isPinned ? Text("Pinned", bundle: .module) : Text(""))
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
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
        ToolbarItem(placement: .primaryAction) {
            Button(String(localized: "New note", bundle: .module), systemImage: "square.and.pencil", action: actions.create)
                .accessibilityIdentifier("library-create")
                .disabled(model.loadState == .signedOut)
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Picker(String(localized: "Collection", bundle: .module), selection: $model.collection) {
                    ForEach(LibraryCollection.allCases) { collection in
                        Label(collection.title, systemImage: collection.symbol).tag(collection)
                    }
                }
            } label: {
                Label(model.collection.title, systemImage: model.collection.symbol)
            }
            .accessibilityIdentifier("library-collection")
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
        if let account = actions.account {
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Account", bundle: .module), systemImage: "person.crop.circle", action: account)
            }
        }
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
    }

    private var matchingTags: [LibraryTag] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.snapshot.tags.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
