#if os(iOS)
import Store
import SwiftUI

private struct LibraryCreateButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(String(localized: "New Gist", bundle: .module), systemImage: "square.and.pencil", action: action)
            .accessibilityIdentifier("library-create")
    }
}

extension View {
    public func libraryRail(
        isVisible: Bool, today: DailyNote,
        create: @escaping @MainActor () -> Void, openToday: @escaping @MainActor () -> Void
    ) -> some View {
        toolbar {
            if isVisible {
                ToolbarItemGroup(placement: .primaryAction) {
                    LibraryCreateButton(action: create)
                    TodayButton(summary: today, action: openToday)
                }
            }
        }
    }

    func deletionConfirmation(
        title: String, isDailyNote: Bool, isPresented: Binding<Bool>, delete: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            String(localized: "Delete “\(title)”?", bundle: .module),
            isPresented: isPresented, titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: .module), role: .destructive, action: delete)
        } message: {
            if isDailyNote {
                Text(
                    "This deletes the daily note from this iPhone and GitHub, including changes that haven’t been published. This can’t be undone.",
                    bundle: .module)
            } else {
                Text(
                    "This deletes the gist from this iPhone and GitHub, including changes that haven’t been published. This can’t be undone.",
                    bundle: .module)
            }
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
    @Bindable private var state: LibraryState
    private let actions: LibraryActions
    private let isSidebar: Bool
    private let isSignedOut: Bool
    private let isLoading: Bool
    private let problem: GitHubProblem?
    private let status: GitHubStatusProblem?
    @Binding private var expandedSections: Set<LibrarySection>
    @Binding private var isPinnedExpanded: Bool
    @State private var collapsedDateGroups: Set<DateGroup> = []
    @State private var pendingDeletion: String?
    @State private var showingTags = false
    @State private var tagQuery = ""
    @State private var isSearchPresented = false
    @ScaledMetric(relativeTo: .body) private var compactRowInset: CGFloat = 16
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `isSidebar` comes from the split view's owner, because a sidebar column always reads as compact.
    public init(
        state: LibraryState, actions: LibraryActions, isSidebar: Bool,
        isSignedOut: Bool = false, isLoading: Bool = false, problem: GitHubProblem? = nil,
        status: GitHubStatusProblem? = nil,
        expandedSections: Binding<Set<LibrarySection>>, isPinnedExpanded: Binding<Bool>
    ) {
        self.state = state
        self.actions = actions
        self.isSidebar = isSidebar
        self.isSignedOut = isSignedOut
        self.isLoading = isLoading
        self.problem = problem
        self.status = status
        _expandedSections = expandedSections
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
        if isSignedOut {
            signedOutInvitation
        } else {
            // Search belongs to the Library column with one placement, so folding and rotating
            // never move it into the detail. A minimized button lands past the overlay sidebar's
            // trailing edge, so the sidebar keeps the full field.
            styledList
                .searchable(text: $state.query, isPresented: $isSearchPresented, placement: .toolbar)
                .searchToolbarBehavior(isSidebar ? .automatic : .minimize)
        }
    }

    @ViewBuilder
    private var styledList: some View {
        if isSidebar {
            libraryList.listStyle(.sidebar)
        } else {
            libraryList.listStyle(.insetGrouped)
        }
    }

    private var navigationTitle: String {
        if isSignedOut { return "" }
        return String(localized: "GistPad", bundle: .module)
    }

    private var navigationSubtitle: String {
        guard !isSignedOut else { return "" }
        return state.mainGistCount.map(LibraryState.gistCountLabel) ?? ""
    }

    private var libraryList: some View {
        // One clock moves rows between date sections and refreshes their relative dates.
        TimelineView(.everyMinute) { context in
            List(selection: selection) {
                if !state.selectedTagIDs.isEmpty {
                    searchScope
                }
                if !pinnedGists.isEmpty {
                    pinnedSection(now: context.date)
                }
                ForEach(dateSections(now: context.date)) { dateSection($0, now: context.date) }
                ForEach(displayedSections) { librarySection($0, now: context.date) }
                if !isLoading && (state.hasFilters ? !state.hasMatches : !hasVisibleGists) {
                    emptyState
                }
            }
        }
        .headerProminence(.increased)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, 44)
        .accessibilityIdentifier("library-list")
        .animation(reduceMotion ? nil : .default, value: state.matchingGists.map(\.id))
    }

    /// The sidebar highlights the open gist. Compact lists push it instead, and losing a
    /// visible row is not leaving the open gist.
    private var selection: Binding<String?> {
        Binding(
            get: { isSidebar ? state.selectedID : nil },
            set: { if let id = $0 { actions.select(id) } })
    }

    private var pinnedGists: [GistItem] {
        state.matchingGists(in: .gists).filter(\.isPinned)
    }

    private func dateSections(now: Date) -> [DateSection] {
        DateSection.sections(
            for: state.matchingGists(in: .gists).filter { !$0.isPinned },
            relativeTo: now, calendar: calendar)
    }

    private func pinnedSection(now: Date) -> some View {
        disclosureSection(isExpanded: $isPinnedExpanded) {
            ForEach(pinnedGists) { gistRow($0, now: now) }
        } header: {
            sectionHeader(
                Text("Pinned", bundle: .module), symbol: "pin", count: pinnedGists.count,
                countLabel: LibraryState.gistCountLabel(pinnedGists.count),
                isExpanded: $isPinnedExpanded, id: "library-section-pinned")
        }
    }

    /// Search results are plain sections, like Notes. Otherwise sections collapse.
    @ViewBuilder
    private func disclosureSection<Rows: View, Header: View>(
        isExpanded: Binding<Bool>, @ViewBuilder rows: () -> Rows, @ViewBuilder header: () -> Header
    ) -> some View {
        if state.hasFilters {
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
        let isCollapsible = !state.hasFilters
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
        let expansion = !isCollapsible ? nil : isExpanded.wrappedValue
            ? String(localized: "Expanded", bundle: .module)
            : String(localized: "Collapsed", bundle: .module)
        let value = [countLabel, expansion].compactMap { $0 }.joined(separator: ", ")
        Group {
            if isSidebar || !isCollapsible {
                label
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    // A plain button only hits its ink, and Notes toggles from anywhere on the header.
                    label.contentShape(.rect)
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

    private var hasVisibleGists: Bool {
        !state.matchingGists(in: .gists).isEmpty || !displayedSections.isEmpty
    }

    private var displayedSections: [LibrarySection] {
        state.secondarySections.filter {
            !state.hasFilters || !state.matchingGists(in: $0).isEmpty
        }
    }

    private func isExpanded(_ section: LibrarySection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { if $0 { expandedSections.insert(section) } else { expandedSections.remove(section) } })
    }

    private func isExpanded(_ group: DateGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedDateGroups.contains(group) },
            set: { if $0 { collapsedDateGroups.remove(group) } else { collapsedDateGroups.insert(group) } })
    }

    private func librarySection(_ section: LibrarySection, now: Date) -> some View {
        let count = state.count(in: section)
        return disclosureSection(isExpanded: isExpanded(section)) {
            ForEach(state.matchingGists(in: section)) { gistRow($0, now: now, section: section) }
        } header: {
            sectionHeader(
                Text(verbatim: section.title), symbol: section.symbol, count: count,
                countLabel: count.map {
                    section == .dailyNotes
                        ? LibraryState.dailyNoteCountLabel($0) : LibraryState.gistCountLabel($0)
                },
                isExpanded: isExpanded(section),
                id: "library-collection-\(section.rawValue)")
        }
    }

    @ViewBuilder
    private func dateSection(_ section: DateSection, now: Date) -> some View {
        if section.group == .undated {
            Section {
                ForEach(section.gists) { gistRow($0, now: now) }
            }
        } else {
            let title = section.group.title(locale: locale, calendar: calendar)
            disclosureSection(isExpanded: isExpanded(section.group)) {
                ForEach(section.gists) { gistRow($0, now: now) }
            } header: {
                sectionHeader(
                    Text(verbatim: title), count: section.gists.count,
                    countLabel: LibraryState.gistCountLabel(section.gists.count),
                    isExpanded: isExpanded(section.group), id: "library-section-\(title)")
            }
        }
    }

    private var statusProblem: GitHubStatusProblem? {
        isSearchPresented ? nil : status
    }

    private var searchScope: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                TagLabels(
                    tags: state.tags.filter { state.selectedTagIDs.contains($0.id) },
                    isSelected: true
                )
                if let count = state.resultGistCount {
                    Text(verbatim: LibraryState.gistCountLabel(count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityIdentifier("library-filter-count")
                }
                Button {
                    state.clearFilters()
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
            GistPadArtwork()
            Text("Welcome to GistPad", bundle: .module)
                .font(.title2.weight(.semibold))
        } description: {
            Text("Your knowledge and daily notes, kept in GitHub gists.", bundle: .module)
        } actions: {
            Button(String(localized: "Sign in with GitHub", bundle: .module), action: actions.reconnect)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("library-sign-in")
        }
    }

    /// With no gists to show, the empty state is also where a failed first load explains itself.
    private var emptyState: some View {
        Section {
            switch problem {
            case _ where state.hasFilters:
                ContentUnavailableView.search(text: state.query)
            case .offline?, .rejected?:
                ContentUnavailableView {
                    Label(String(localized: "Couldn't Load Your Gists", bundle: .module), systemImage: "exclamationmark.circle")
                } description: {
                    Text("GitHub couldn't be reached. Your gists will appear once it answers.", bundle: .module)
                } actions: {
                    Button(String(localized: "Try Again", bundle: .module)) {
                        Task { await actions.refresh() }
                    }
                }
            case .reconnect?:
                ContentUnavailableView {
                    Label(String(localized: "Reconnect GitHub", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Sign in with GitHub again to see your gists.", bundle: .module)
                } actions: {
                    Button(String(localized: "Sign in with GitHub", bundle: .module), action: actions.reconnect)
                }
            case nil:
                ContentUnavailableView {
                    GistPadArtwork()
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

    private func gistRow(
        _ gist: GistItem, now: Date, section: LibrarySection = .gists
    ) -> some View {
        NavigationLink(value: gist.id) {
            GistRow(
                gist: gist, tags: state.tags(for: gist), now: now,
                showsStar: section != .starred)
        }
        .accessibilityIdentifier("library-note-\(gist.id)")
        .navigationLinkIndicatorVisibility(.hidden)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        // The row's own padding is its whole vertical rhythm, so the List adds none.
        .listRowInsets(.vertical, 0)
        // Compact rows sit 16 pt inside the card. The sidebar keeps the system inset.
        .listRowInsets(.horizontal, isSidebar ? nil : compactRowInset)
        .contextMenu { rowActions(gist) }
        .accessibilityActions {
            if gist.supportsComments {
                Button(String(localized: "Open Comments", bundle: .module)) { actions.openComments(gist.id) }
            }
        }
        .deletionConfirmation(
            title: gist.displayTitle(now: now, locale: locale, calendar: calendar),
            isDailyNote: gist.isDailyNote,
            isPresented: Binding(
                get: { pendingDeletion == gist.id },
                set: { if !$0 { pendingDeletion = nil } }),
            delete: { actions.delete(gist.id) })
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if gist.isOwned {
                // The confirmation owns the destructive role, not this pending swipe.
                Button(String(localized: "Delete", bundle: .module), systemImage: "trash") {
                    pendingDeletion = gist.id
                }
                .labelStyle(.iconOnly)
                .tint(.red)
            }
            if gist.canPinAndArchive {
                Button {
                    actions.toggleArchive(gist.id)
                } label: {
                    Label(
                        gist.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                        systemImage: gist.isArchived ? "arrow.up.bin" : "archivebox"
                    )
                }
                .labelStyle(.iconOnly)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if gist.canPinAndArchive {
                Button {
                    actions.togglePin(gist.id)
                } label: {
                    Label(
                        gist.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                        systemImage: gist.isPinned ? "pin.slash" : "pin"
                    )
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ gist: GistItem) -> some View {
        if gist.supportsComments {
            Button(
                String(localized: "Open Comments", bundle: .module), systemImage: "text.bubble"
            ) { actions.openComments(gist.id) }
        }
        if gist.canPinAndArchive {
            Button(
                gist.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                systemImage: gist.isPinned ? "pin.slash" : "pin"
            ) { actions.togglePin(gist.id) }
            Button(
                gist.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                systemImage: gist.isArchived ? "arrow.up.bin" : "archivebox"
            ) { actions.toggleArchive(gist.id) }
        }
        if gist.isOwned {
            Divider()
            Button(
                String(localized: "Delete", bundle: .module), systemImage: "trash",
                role: .destructive
            ) { pendingDeletion = gist.id }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if !isSignedOut {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if !isSearchPresented {
                if let statusProblem {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        GitHubStatusControl(state: .problem(statusProblem), recover: actions.recoverStatus)
                    }
                    .axisBehavior(.verticalPreferred)
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    tagFilterButton
                }
            }
            if !isSidebar {
                ToolbarItemGroup(placement: .primaryAction) {
                    LibraryCreateButton(action: actions.create)
                    TodayButton(summary: state.today, action: actions.today)
                    settingsButton
                }
            }
        }
        if isSidebar || isSignedOut {
            ToolbarItem(placement: .primaryAction) {
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
        // The system blue that confirm buttons use, not the personal accent.
        .tint(state.selectedTagIDs.isEmpty ? .primary : Color(uiColor: .tintColor))
        .disabled(state.tags.isEmpty)
        .accessibilityValue(Text("\(state.selectedTagIDs.count) selected", bundle: .module))
        .accessibilityIdentifier("library-filter-tags")
    }

    private var tagFilters: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matchingTags) { tag in
                        Button {
                            if state.selectedTagIDs.contains(tag.id) {
                                state.selectedTagIDs.remove(tag.id)
                            } else {
                                state.selectedTagIDs.insert(tag.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                TagSwatch(hex: tag.colorHex)
                                Text(verbatim: tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(state.gistCount(tagged: tag.id), format: .number)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                // Reserves its width so the count never shifts when a tag is selected.
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .opacity(state.selectedTagIDs.contains(tag.id) ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(Text(verbatim: LibraryState.gistCountLabel(state.gistCount(tagged: tag.id))))
                        .accessibilityAddTraits(state.selectedTagIDs.contains(tag.id) ? .isSelected : [])
                        .accessibilityIdentifier("library-tag-filter-\(tag.id)")
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state.selectedTagIDs.contains(tag.id))
                    }
                }
                if !state.selectedTagIDs.isEmpty {
                    Button(String(localized: "Clear tag filters", bundle: .module)) {
                        state.selectedTagIDs = []
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
                        .accessibilityIdentifier("library-tag-filter-close")
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var matchingTags: [Tag] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.tags.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
