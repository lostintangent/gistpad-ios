#if os(iOS)
import GistPadSync
import SwiftUI

extension EnvironmentValues {
    @Entry var isLibrarySearchPresented = false
}

private struct LibrarySearchModifier: ViewModifier {
    @Bindable var model: LibraryModel
    @State private var isPresented = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        searchableContent(content)
            .searchToolbarBehavior(.minimize)
            .environment(\.isLibrarySearchPresented, isPresented)
    }

    @ViewBuilder
    private func searchableContent(_ content: Content) -> some View {
        if model.loadState == .signedOut {
            content
        } else {
            content.searchable(
                text: $model.query, isPresented: $isPresented,
                placement: horizontalSizeClass == .regular ? .sidebar : .automatic
            )
        }
    }
}

private struct LibraryCreateButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(String(localized: "New Gist", bundle: .module), systemImage: "square.and.pencil", action: action)
            .accessibilityIdentifier("library-create")
    }
}

extension View {
    public func librarySearch(model: LibraryModel) -> some View {
        modifier(LibrarySearchModifier(model: model))
    }

    public func libraryRail(
        isVisible: Bool, today: DailyNote, isTodaySelected: Bool,
        create: @escaping @MainActor () -> Void, openToday: @escaping @MainActor () -> Void
    ) -> some View {
        toolbar {
            if isVisible {
                ToolbarItemGroup(placement: .primaryAction) {
                    LibraryCreateButton(action: create)
                    LibraryTodayButton(summary: today, isSelected: isTodaySelected, action: openToday)
                }
            }
        }
    }

    func deletionConfirmation(
        title: String, isPresented: Binding<Bool>, delete: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            String(localized: "Delete “\(title)”?", bundle: .module),
            isPresented: isPresented, titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: .module), role: .destructive, action: delete)
        } message: {
            Text(
                "This removes the note from this iPhone and from GitHub if it was saved there, including unsynced changes. This can’t be undone.",
                bundle: .module)
        }
    }
}

@MainActor
public struct LibraryActions {
    public var refresh: () async -> Void
    public var create: @MainActor () -> Void
    public var today: @MainActor () -> Void
    public var select: (String) -> Void = { _ in }
    public var reconnect: () -> Void = {}
    public var recoverStatus: () -> Void = {}
    public var account: () -> Void = {}
    public var togglePin: (String) -> Void = { _ in }
    public var toggleArchive: (String) -> Void = { _ in }
    public var openComments: (String) -> Void = { _ in }
    public var delete: (String) -> Void = { _ in }

    public init(
        refresh: @escaping () async -> Void,
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
    private let isTodaySelected: Bool
    private let isSidebar: Bool
    @Binding private var expandedCollections: Set<LibraryCollection>
    @Binding private var isPinnedExpanded: Bool
    @State private var collapsedDateGroups: Set<LibraryDateGroup> = []
    @State private var pendingDeletion: String?
    @State private var showingTags = false
    @State private var tagQuery = ""
    @ScaledMetric(relativeTo: .body) private var compactRowInset: CGFloat = 16
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLibrarySearchPresented) private var isSearchPresented

    /// `isSidebar` comes from the split view's owner, because a sidebar column always reads as compact.
    public init(
        model: LibraryModel, actions: LibraryActions, isSidebar: Bool, isTodaySelected: Bool = false,
        expandedCollections: Binding<Set<LibraryCollection>>, isPinnedExpanded: Binding<Bool>
    ) {
        self.model = model
        self.actions = actions
        self.isSidebar = isSidebar
        self.isTodaySelected = isTodaySelected
        _expandedCollections = expandedCollections
        _isPinnedExpanded = isPinnedExpanded
    }

    public var body: some View {
        navigationList
            .navigationTitle(navigationTitle)
            .navigationSubtitle(navigationSubtitle)
            .toolbarTitleDisplayMode(.large)
            .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 400)
            .refreshable { await actions.refresh() }
            .toolbar { libraryToolbar }
            .sheet(isPresented: $showingTags) { tagFilters }
            .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder
    private var navigationList: some View {
        if model.loadState == .signedOut {
            signedOutInvitation
        } else if isSidebar {
            libraryList.listStyle(.sidebar)
        } else {
            libraryList.listStyle(.insetGrouped)
        }
    }

    private var navigationTitle: String {
        if model.loadState == .signedOut { return "" }
        return String(localized: "GistPad", bundle: .module)
    }

    private var navigationSubtitle: String {
        guard model.loadState != .signedOut else { return "" }
        return model.mainGistCount.map(LibraryModel.gistCountLabel) ?? ""
    }

    private var libraryList: some View {
        // One clock moves rows between date sections and refreshes their relative dates.
        TimelineView(.everyMinute) { context in
            List(selection: selection) {
                if !model.selectedTagIDs.isEmpty {
                    searchScope
                }
                if !pinnedNotes.isEmpty {
                    pinnedSection(now: context.date)
                }
                ForEach(dateSections(now: context.date)) { dateSection($0, now: context.date) }
                ForEach(displayedCollections) { collectionSection($0, now: context.date) }
                if !hasVisibleNotes && model.loadState != .loading {
                    emptyState
                }
            }
        }
        .headerProminence(.increased)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, 44)
        .accessibilityIdentifier("library-list")
        .animation(reduceMotion ? nil : .default, value: model.matchingNotes.map(\.id))
    }

    /// The sidebar highlights the open gist. Compact lists push it instead, and losing a
    /// visible row is not leaving the open gist.
    private var selection: Binding<String?> {
        Binding(
            get: { isSidebar ? model.selectedNoteID : nil },
            set: { if let id = $0 { actions.select(id) } })
    }

    private var pinnedNotes: [LibraryNote] {
        model.matchingNotes(in: .gists).filter(\.isPinned)
    }

    private func dateSections(now: Date) -> [LibraryDateSection] {
        LibraryDateSection.sections(
            for: model.matchingNotes(in: .gists).filter { !$0.isPinned },
            relativeTo: now, calendar: calendar)
    }

    private func pinnedSection(now: Date) -> some View {
        disclosureSection(isExpanded: $isPinnedExpanded) {
            ForEach(pinnedNotes) { noteRow($0, now: now) }
        } header: {
            sectionHeader(
                Text("Pinned", bundle: .module), symbol: "pin", count: pinnedNotes.count,
                countLabel: LibraryModel.gistCountLabel(pinnedNotes.count),
                isExpanded: $isPinnedExpanded, id: "library-section-pinned")
        }
    }

    /// Search results are plain sections, like Notes. Otherwise sections collapse.
    @ViewBuilder
    private func disclosureSection<Rows: View, Header: View>(
        isExpanded: Binding<Bool>, @ViewBuilder rows: () -> Rows, @ViewBuilder header: () -> Header
    ) -> some View {
        if model.hasFilters {
            Section { rows() } header: { header() }
        } else {
            Section(isExpanded: isExpanded) { rows() } header: { header() }
        }
    }

    /// Compact `.insetGrouped` draws no disclosure, so there the whole header is one disclosure
    /// button ending in Notes' circled chevron. The sidebar draws and handles its own.
    @ViewBuilder
    private func sectionHeader(
        _ title: Text, symbol: String? = nil, count: Int?, countLabel: String?,
        isExpanded: Binding<Bool>, id: String
    ) -> some View {
        let isCollapsible = !model.hasFilters
        // At accessibility sizes the sidebar header keeps only its title, so it wraps between
        // words. VoiceOver still reads the count from the header's value.
        let titleOnly = isSidebar && dynamicTypeSize.isAccessibilitySize
        let label = HStack(alignment: .firstTextBaseline) {
            if let symbol, !titleOnly {
                Label { title } icon: { Image(systemName: symbol) }
            } else {
                title
            }
            Spacer(minLength: 8)
            if let count, !titleOnly {
                let number = Text(count, format: .number).monospacedDigit()
                // The sidebar already draws its headers in secondary ink, so the count shares it.
                (isSidebar ? number : number.foregroundStyle(.secondary))
                    .fixedSize()
            }
            if !isSidebar && isCollapsible {
                // UIKit's secondary label, which is what Notes' disc uses (SwiftUI's
                // hierarchical `.secondary` renders a flatter, different gray).
                Image(
                    systemName: isExpanded.wrappedValue
                        ? "chevron.down.circle.fill" : "chevron.forward.circle.fill"
                )
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .contentTransition(.symbolEffect(.replace))
            }
        }
        let state = !isCollapsible ? nil : isExpanded.wrappedValue
            ? String(localized: "Expanded", bundle: .module)
            : String(localized: "Collapsed", bundle: .module)
        let value = [countLabel, state].compactMap { $0 }.joined(separator: ", ")
        Group {
            if isSidebar || !isCollapsible {
                label
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(id)
    }

    private var hasVisibleNotes: Bool {
        !model.matchingNotes(in: .gists).isEmpty || !displayedCollections.isEmpty
    }

    private var displayedCollections: [LibraryCollection] {
        model.secondaryCollections.filter {
            !model.hasFilters || !model.matchingNotes(in: $0).isEmpty
        }
    }

    private func isExpanded(_ collection: LibraryCollection) -> Binding<Bool> {
        Binding(
            get: { expandedCollections.contains(collection) },
            set: { if $0 { expandedCollections.insert(collection) } else { expandedCollections.remove(collection) } })
    }

    private func isExpanded(_ group: LibraryDateGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedDateGroups.contains(group) },
            set: { if $0 { collapsedDateGroups.remove(group) } else { collapsedDateGroups.insert(group) } })
    }

    private func collectionSection(_ collection: LibraryCollection, now: Date) -> some View {
        let count = model.count(in: collection)
        return disclosureSection(isExpanded: isExpanded(collection)) {
            ForEach(model.matchingNotes(in: collection)) { noteRow($0, now: now, collection: collection) }
        } header: {
            sectionHeader(
                Text(verbatim: collection.title), symbol: collection.symbol, count: count,
                countLabel: count.map {
                    collection == .dailyNotes
                        ? LibraryModel.noteCountLabel($0) : LibraryModel.gistCountLabel($0)
                },
                isExpanded: isExpanded(collection),
                id: "library-collection-\(collection.rawValue)")
        }
    }

    @ViewBuilder
    private func dateSection(_ section: LibraryDateSection, now: Date) -> some View {
        if section.group == .undated {
            Section {
                ForEach(section.notes) { noteRow($0, now: now) }
            }
        } else {
            let title = section.group.title(locale: locale, calendar: calendar)
            disclosureSection(isExpanded: isExpanded(section.group)) {
                ForEach(section.notes) { noteRow($0, now: now) }
            } header: {
                sectionHeader(
                    Text(verbatim: title), count: section.notes.count,
                    countLabel: LibraryModel.gistCountLabel(section.notes.count),
                    isExpanded: isExpanded(section.group), id: "library-section-\(title)")
            }
        }
    }

    private var statusProblem: GitHubStatusState? {
        guard !isSearchPresented, case .problem = model.gitHubStatus else { return nil }
        return model.gitHubStatus
    }

    private var searchScope: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                TagLabels(
                    tags: model.snapshot.tags.filter { model.selectedTagIDs.contains($0.id) },
                    isSelected: true
                )
                if let count = model.resultGistCount {
                    Text(verbatim: LibraryModel.gistCountLabel(count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityIdentifier("library-filter-count")
                }
                Button {
                    model.clearFilters()
                } label: {
                    Label {
                        Text("Clear Tag Filter", bundle: .module)
                    } icon: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("library-filter-clear")
            }
            .padding(.vertical, 4)
        }
    }

    private var signedOutInvitation: some View {
        ContentUnavailableView {
            NotebookArtwork()
            Text("Your gists, on GitHub", bundle: .module)
                .font(.title2.weight(.semibold))
        } description: {
            Text("Markdown and daily notes, kept in your GitHub gists.", bundle: .module)
        } actions: {
            Button(String(localized: "Continue with GitHub", bundle: .module), action: actions.reconnect)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("library-sign-in")
        }
    }

    /// With no gists to show, the empty state is also where a failed first load explains itself.
    private var emptyState: some View {
        Section {
            switch model.loadState {
            case _ where model.hasFilters:
                ContentUnavailableView.search(text: model.query)
            case .failed(let message):
                ContentUnavailableView {
                    Label(String(localized: "Couldn't update from GitHub.", bundle: .module), systemImage: "exclamationmark.circle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button(String(localized: "Retry", bundle: .module)) {
                        Task { await actions.refresh() }
                    }
                }
            case .reconnectRequired(let message):
                ContentUnavailableView {
                    Label(String(localized: "Reconnect GitHub", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button(String(localized: "Continue with GitHub", bundle: .module), action: actions.reconnect)
                }
            default:
                ContentUnavailableView {
                    NotebookArtwork()
                    Text("No Gists Yet", bundle: .module)
                        .font(.title2.weight(.semibold))
                } description: {
                    Text("A thought, a list, a little thing worth keeping. Start your first gist.", bundle: .module)
                } actions: {
                    Button(String(localized: "New Gist", bundle: .module), action: actions.create)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func noteRow(
        _ note: LibraryNote, now: Date, collection: LibraryCollection = .gists
    ) -> some View {
        NavigationLink(value: note.id) {
            LibraryNoteRow(
                note: note, tags: model.tags(for: note), now: now,
                showsStar: collection != .starred)
        }
        .accessibilityIdentifier("library-note-\(note.id)")
        .navigationLinkIndicatorVisibility(.hidden)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        // The row's own padding is its whole vertical rhythm, so the List adds none.
        .listRowInsets(.vertical, 0)
        // Compact rows sit 16 pt inside the card. The sidebar keeps the system inset.
        .listRowInsets(.horizontal, isSidebar ? nil : compactRowInset)
        .contextMenu { rowActions(note) }
        .accessibilityActions {
            if note.supportsComments {
                Button(String(localized: "Open Comments", bundle: .module)) { actions.openComments(note.id) }
            }
        }
        .deletionConfirmation(
            title: note.title,
            isPresented: Binding(
                get: { pendingDeletion == note.id },
                set: { if !$0 { pendingDeletion = nil } }),
            delete: { actions.delete(note.id) })
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if note.isOwned {
                // The confirmation owns the destructive role, not this pending swipe.
                Button(String(localized: "Delete", bundle: .module), systemImage: "trash") {
                    pendingDeletion = note.id
                }
                .tint(.red)
            }
            if note.isOwned, !note.isRecovery {
                Button {
                    actions.toggleArchive(note.id)
                } label: {
                    Label(
                        note.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                        systemImage: "archivebox"
                    )
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if note.isOwned, !note.isRecovery {
                Button {
                    actions.togglePin(note.id)
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
        if note.supportsComments {
            Button(
                String(localized: "Open Comments", bundle: .module), systemImage: "text.bubble"
            ) { actions.openComments(note.id) }
        }
        if note.isOwned, !note.isRecovery {
            Button(
                note.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                systemImage: note.isPinned ? "pin.slash" : "pin"
            ) { actions.togglePin(note.id) }
            Button(
                note.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                systemImage: "archivebox"
            ) { actions.toggleArchive(note.id) }
        }
        if note.isOwned {
            Divider()
            Button(
                String(localized: "Delete", bundle: .module), systemImage: "trash",
                role: .destructive
            ) { pendingDeletion = note.id }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if model.loadState != .signedOut {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if !isSearchPresented {
                if let statusProblem {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        GitHubStatusControl(state: statusProblem, recover: actions.recoverStatus)
                    }
                    .axisBehavior(.verticalPreferred)
                    .sharedBackgroundVisibility(.hidden)
                }
                if !isSidebar {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        tagFilterButton
                    }
                }
            }
            if !isSidebar {
                ToolbarItemGroup(placement: .primaryAction) {
                    LibraryCreateButton(action: actions.create)
                    LibraryTodayButton(
                        summary: model.today, isSelected: isTodaySelected, action: actions.today)
                    settingsButton
                }
            }
            if isSidebar {
                ToolbarItem(placement: .secondaryAction) {
                    tagFilterButton
                }
            }
        }
        if isSidebar || model.loadState == .signedOut {
            ToolbarItem(placement: .secondaryAction) {
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button(String(localized: "Settings", bundle: .module), systemImage: "gearshape", action: actions.account)
            .accessibilityIdentifier("library-settings")
    }

    private var tagFilterButton: some View {
        Button(String(localized: "Filter by tags", bundle: .module), systemImage: "tag") {
            showingTags = true
        }
        .symbolVariant(model.selectedTagIDs.isEmpty ? .none : .fill)
        .disabled(model.snapshot.tags.isEmpty)
        .accessibilityValue(Text("\(model.selectedTagIDs.count) selected", bundle: .module))
        .accessibilityIdentifier("library-filter-tags")
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
                                Text(model.gistCount(tagged: tag.id), format: .number)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                // Reserves its width so the count never shifts when a tag is selected.
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .opacity(model.selectedTagIDs.contains(tag.id) ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(Text(verbatim: LibraryModel.gistCountLabel(model.gistCount(tagged: tag.id))))
                        .accessibilityAddTraits(model.selectedTagIDs.contains(tag.id) ? .isSelected : [])
                        .accessibilityIdentifier("library-tag-filter-\(tag.id)")
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.selectedTagIDs.contains(tag.id))
                    }
                }
                if !model.selectedTagIDs.isEmpty {
                    Button(String(localized: "Clear tag filters", bundle: .module)) {
                        model.selectedTagIDs = []
                    }
                }
            }
            .navigationTitle(Text("Filter by tags", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $tagQuery, prompt: Text("Search tags", bundle: .module))
            .overlay {
                if matchingTags.isEmpty {
                    ContentUnavailableView.search(text: tagQuery)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { showingTags = false }
                        .accessibilityLabel(Text("Close", bundle: .module))
                        .accessibilityIdentifier("library-tag-filter-close")
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
