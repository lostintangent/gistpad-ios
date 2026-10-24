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
    @State private var showingTags = false
    @State private var tagQuery = ""

    public init(model: LibraryModel, actions: LibraryActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        List(selection: $model.selectedNoteID) {
            status
            if model.loadState != .signedOut {
                if model.collection == .gists && !model.hasFilters {
                    Section {
                        Button(action: actions.today) {
                            Label(String(localized: "Today", bundle: .module), systemImage: "calendar")
                                .foregroundStyle(InterfaceTheme.accent)
                                .padding(.vertical, 6)
                        }
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
                            Label(
                                model.snapshot.tags.filter { model.selectedTagIDs.contains($0.id) }
                                    .map(\.name).sorted().joined(separator: ", "),
                                systemImage: "tag"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } footer: {
                        if !model.selectedTagIDs.isEmpty {
                            Text("All selected tags must match.", bundle: .module)
                        }
                    }
                }
                if let open = model.openDocumentOutsideFilter {
                    Section(String(localized: "Open document", bundle: .module)) {
                        noteRow(open)
                    }
                }
                if !model.pinnedNotes.isEmpty {
                    Section(String(localized: "Pinned", bundle: .module)) {
                        ForEach(model.pinnedNotes) { noteRow($0) }
                    }
                }
                if !model.unpinnedNotes.isEmpty {
                    Section(model.collection.title) {
                        ForEach(model.unpinnedNotes) { noteRow($0) }
                    }
                }
                if model.matchingNotes.isEmpty && model.loadState != .loading {
                    emptyState
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("GistPad")
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        .searchable(
            text: $model.query,
            prompt: Text("Search titles", bundle: .module)
        )
        .refreshable { await actions.refresh() }
        .toolbar { libraryToolbar }
        .sheet(isPresented: $showingTags) { tagFilters }
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
                    .foregroundStyle(.secondary)
                Button(String(localized: "Retry", bundle: .module)) {
                    Task { await actions.refresh() }
                }
            }
        case .reconnectRequired(let message):
            Section {
                Label(String(localized: "Reconnect GitHub", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let reconnect = actions.reconnect {
                    Button(String(localized: "Continue with GitHub", bundle: .module), action: reconnect)
                }
            }
        case .signedOut:
            Section {
                ContentUnavailableView {
                    Label(String(localized: "Your notebook, on GitHub", bundle: .module), systemImage: "book.closed")
                } description: {
                    Text("Reconnect your account to see your gists, tags and pins. Local drafts stay on this iPhone.", bundle: .module)
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
                        ? String(localized: "No matching gists", bundle: .module)
                        : String(localized: "No gists here yet", bundle: .module),
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
                    Button(String(localized: "Create a gist", bundle: .module), action: actions.create)
                } else if model.collection == .dailyNotes {
                    Button(String(localized: "Start today's note", bundle: .module), action: actions.today)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func noteRow(_ note: LibraryNote) -> some View {
        NavigationLink(value: note.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: note.title)
                        .font(.headline)
                        .lineLimit(2)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.subheadline)
                            .foregroundStyle(InterfaceTheme.accent)
                            .accessibilityLabel(Text("Pinned", bundle: .module))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !note.isOwned, let owner = note.owner {
                        Text(verbatim: "@\(owner)")
                    }
                    Text(note.updatedAt, format: .relative(presentation: .named))
                    if !model.tags(for: note).isEmpty {
                        Text(verbatim: model.tags(for: note).map(\.name).joined(separator: ", "))
                            .accessibilityLabel(
                                Text("Tags: \(model.tags(for: note).map(\.name).joined(separator: ", "))", bundle: .module)
                            )
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
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
            Button(String(localized: "New gist", bundle: .module), systemImage: "square.and.pencil", action: actions.create)
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
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(model.selectedTagIDs.contains(tag.id) ? .isSelected : [])
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
