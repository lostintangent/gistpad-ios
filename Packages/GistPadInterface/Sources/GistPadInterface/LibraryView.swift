#if os(iOS)
import SwiftUI

private struct LibrarySearchOwnerKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LibrarySearchPresentationKey: EnvironmentKey {
    static var defaultValue: Binding<Bool>? { nil }
}

extension EnvironmentValues {
    fileprivate var librarySearchManagedByContainer: Bool {
        get { self[LibrarySearchOwnerKey.self] }
        set { self[LibrarySearchOwnerKey.self] = newValue }
    }

    fileprivate var librarySearchPresentation: Binding<Bool>? {
        get { self[LibrarySearchPresentationKey.self] }
        set { self[LibrarySearchPresentationKey.self] = newValue }
    }
}

private struct LibrarySearchModifier: ViewModifier {
    @Bindable var model: LibraryModel
    var isPresented: Binding<Bool>?
    var sidebarOverride: Bool?
    @State private var presented = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var presentation: Binding<Bool> { isPresented ?? $presented }
    private var isSidebar: Bool { sidebarOverride ?? (horizontalSizeClass == .regular) }

    func body(content: Content) -> some View {
        searchableContent(content)
            .searchToolbarBehavior(isSidebar ? .minimize : .automatic)
            .environment(\.librarySearchManagedByContainer, true)
            .environment(\.librarySearchPresentation, presentation)
    }

    @ViewBuilder
    private func searchableContent(_ content: Content) -> some View {
        if model.loadState == .signedOut || !isSidebar {
            content
        } else {
            content.searchable(
                text: $model.query, isPresented: presentation,
                placement: .sidebar,
                prompt: Text("Search notes", bundle: .module)
            )
        }
    }
}

private struct LibraryCreateButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(String(localized: "New note", bundle: .module), systemImage: "square.and.pencil", action: action)
            .tint(.primary)
            .accessibilityIdentifier("library-create")
    }
}

extension View {
    public func librarySearch(
        model: LibraryModel, isPresented: Binding<Bool>? = nil, isSidebar: Bool? = nil
    ) -> some View {
        modifier(LibrarySearchModifier(
            model: model, isPresented: isPresented, sidebarOverride: isSidebar))
    }

    public func libraryRail(
        isVisible: Bool, today: LibraryTodaySummary, isTodaySelected: Bool,
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
}

@MainActor
public struct LibraryDeletionConfirmation {
    public let rowID: String
    public let title: String
    public let isLocalCopy: Bool
    let confirm: () -> Void
    let dismiss: () -> Void

    public init(
        rowID: String, title: String, isLocalCopy: Bool = false, confirm: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.rowID = rowID
        self.title = title
        self.isLocalCopy = isLocalCopy
        self.confirm = confirm
        self.dismiss = dismiss
    }
}

private struct LibraryRowDeletionConfirmation: ViewModifier {
    let rowID: String
    let target: LibraryDeletionConfirmation?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target?.isLocalCopy == true
                ? String(localized: "Delete local copy of “\(target?.title ?? "")”?", bundle: .module)
                : String(localized: "Delete “\(target?.title ?? "")” from GitHub?", bundle: .module),
            isPresented: Binding(
                get: { target?.rowID == rowID },
                set: { if !$0, target?.rowID == rowID { target?.dismiss() } }),
            titleVisibility: .visible
        ) {
            Button(
                target?.isLocalCopy == true
                    ? String(localized: "Delete Local Copy", bundle: .module)
                    : String(localized: "Delete from GitHub", bundle: .module),
                role: .destructive
            ) {
                target?.confirm()
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            if target?.isLocalCopy == true {
                Text(
                    "This removes this local copy, its pending photos and local history from this iPhone. It doesn't delete anything on GitHub. This cannot be undone.",
                    bundle: .module)
            } else {
                Text(
                    "This deletes every file from GitHub and this iPhone, including unsynced drafts and local history. This cannot be undone.",
                    bundle: .module)
            }
        }
    }
}

private struct LibraryCommentsAccessibilityAction: ViewModifier {
    let note: LibraryNote
    let action: (@MainActor (String) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if note.supportsComments, let action {
            content.accessibilityAction(
                named: Text("Open Comments", bundle: .module)
            ) { action(note.id) }
        } else {
            content
        }
    }
}

public struct LibraryActions {
    public var refresh: @MainActor () async -> Void
    public var create: @MainActor () -> Void
    public var today: @MainActor () -> Void
    public var select: (@MainActor (String) -> Void)?
    public var reconnect: (@MainActor () -> Void)?
    public var recoverStatus: (@MainActor () -> Void)?
    public var account: (@MainActor () -> Void)?
    public var togglePin: (@MainActor (String) -> Void)?
    public var toggleArchive: (@MainActor (String) -> Void)?
    public var openComments: (@MainActor (String) -> Void)?
    public var delete: (@MainActor (String) -> Void)?
    public var deletionConfirmation: LibraryDeletionConfirmation?

    public init(
        refresh: @escaping @MainActor () async -> Void,
        create: @escaping @MainActor () -> Void,
        today: @escaping @MainActor () -> Void
    ) {
        self.refresh = refresh
        self.create = create
        self.today = today
    }

    @MainActor
    func deletionAction(for note: LibraryNote) -> (@MainActor () -> Void)? {
        guard note.isOwned, note.canDeleteFromGitHub || note.isRecovery, let delete else { return nil }
        return { delete(note.id) }
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
    private struct Selection: Hashable {
        let collection: LibraryCollection
        let noteID: String
    }

    struct SearchSummary: View {
        let coverage: LibrarySearchCoverage?
        let selectedTagCount: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let coverage {
                    if coverage.documentsWithCachedContent == coverage.totalDocuments {
                        Text("Searches titles, filenames, tags and note text.", bundle: .module)
                    } else {
                        Text(
                            "Searches titles, filenames and tags, plus text from \(coverage.documentsWithCachedContent) of \(coverage.totalDocuments) notes.",
                            bundle: .module
                        )
                    }
                    if coverage.incompleteGistCount > 0 {
                        Text("\(coverage.incompleteGistCount) gists have incomplete file lists.", bundle: .module)
                    }
                    if coverage.staleResultCount > 0 {
                        Text("\(coverage.staleResultCount) results have older cached content.", bundle: .module)
                    }
                } else {
                    Text("Searches note titles.", bundle: .module)
                }
                if selectedTagCount > 1 {
                    Text("Matches all selected tags.", bundle: .module)
                }
            }
            .font(.footnote)
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .textCase(nil)
            .accessibilityIdentifier("library-search-coverage")
        }
    }

    @Bindable private var model: LibraryModel
    private let actions: LibraryActions
    private let footer: Text?
    private let isTodaySelected: Bool
    private let sidebarOverride: Bool?
    private let savedCollections: Binding<Set<LibraryCollection>>?
    @State private var localCollections: Set<LibraryCollection> = []
    @State private var collapsedSearchCollections: Set<LibraryCollection> = []
    @State private var selectedCollection: LibraryCollection = .gists
    @State private var deletionSelection: Selection?
    @State private var showingTags = false
    @State private var tagQuery = ""
    @State private var isPullRefreshing = false
    @State private var searchPresented = false
    @State private var windowContentWidth: CGFloat?
    @ScaledMetric(relativeTo: .body) private var headingCountSpacing = 4
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.librarySearchManagedByContainer) private var searchManagedByContainer
    @Environment(\.librarySearchPresentation) private var containerSearchPresentation
    @Environment(\.isGitHubStatusVisible) private var isGitHubStatusVisible

    public init(
        model: LibraryModel, actions: LibraryActions, footer: Text? = nil,
        isTodaySelected: Bool = false, isSidebar: Bool? = nil,
        expandedCollections: Binding<Set<LibraryCollection>>? = nil
    ) {
        self.model = model
        self.actions = actions
        self.footer = footer
        self.isTodaySelected = isTodaySelected
        sidebarOverride = isSidebar
        savedCollections = expandedCollections
    }

    #if DEBUG
    public func captureTagFilters(_ value: Bool) -> Self {
        var library = self
        library._showingTags = State(initialValue: value)
        return library
    }
    #endif

    public var body: some View {
        GeometryReader { geometry in
            navigationList
                .navigationTitle(navigationTitle)
                .navigationSubtitle(navigationSubtitle)
                .toolbarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 400)
                .refreshable {
                    isPullRefreshing = true
                    defer { isPullRefreshing = false }
                    await actions.refresh()
                }
                .toolbar { libraryToolbar }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    if !isSidebar, model.loadState != .signedOut {
                        LibrarySearchField(
                            text: $model.query,
                            isPresented: containerSearchPresentation ?? $searchPresented,
                            windowContentWidth: $windowContentWidth
                        )
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 56)
                        .padding(.horizontal, 12)
                        .padding(
                            .bottom,
                            dynamicTypeSize.isAccessibilitySize && hasSideToolbar(in: geometry)
                                ? 14 : 20)
                        .ignoresSafeArea(
                            .container, edges: hasSideToolbar(in: geometry) ? .bottom : [])
                    }
                }
                .sheet(isPresented: $showingTags) { tagFilters }
                .scrollEdgeEffectStyle(.soft, for: .all)
        }
        .onChange(of: model.query) { resetSearchDisclosures() }
        .onChange(of: model.selectedTagIDs) { resetSearchDisclosures() }
        .onChange(of: actions.deletionConfirmation?.rowID) { _, rowID in
            if rowID == nil { deletionSelection = nil }
        }
    }

    @ViewBuilder
    private var navigationList: some View {
        if model.loadState == .signedOut {
            signedOutInvitation
        } else if searchManagedByContainer || !isSidebar {
            adaptiveList
        } else {
            adaptiveList
                .searchable(
                    text: $model.query, isPresented: $searchPresented,
                    placement: .sidebar,
                    prompt: Text("Search notes", bundle: .module))
                .searchToolbarBehavior(isSidebar ? .minimize : .automatic)
        }
    }

    @ViewBuilder
    private var adaptiveList: some View {
        if isSidebar {
            libraryList.listStyle(.sidebar)
        } else {
            libraryList
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private var isSidebar: Bool { sidebarOverride ?? (horizontalSizeClass == .regular) }

    private func hasSideToolbar(in geometry: GeometryProxy) -> Bool {
        guard let windowContentWidth else { return false }
        let availableWidth = geometry.size.width
            - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing
        return windowContentWidth - availableWidth > 1
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
        List(selection: librarySelection) {
            status
            if model.loadState != .signedOut {
                if !model.selectedTagIDs.isEmpty {
                    searchScope
                }
                searchStatus
                if model.hasFilters {
                    Section {} header: { searchSummary }
                        .listSectionMargins(.vertical, 0)
                }
                if !pinnedCards.isEmpty {
                    Section {
                        ForEach(pinnedCards) { noteRow($0, isCard: true) }
                    }
                    .listSectionMargins(.top, 16)
                    .listSectionMargins(.bottom, mainNotes.isEmpty ? 0 : 24)
                    .listSectionMargins(.vertical, 0)
                    .listSectionSeparator(.hidden)
                }
                if !mainNotes.isEmpty {
                    Section {
                        ForEach(mainNotes) { note in
                            noteRow(note, hidesTopSeparator: note.id == mainNotes.first?.id)
                        }
                    }
                    .listSectionMargins(.top, pinnedCards.isEmpty && !model.hasFilters ? 8 : 0)
                    .listSectionMargins(.vertical, 0)
                    .listSectionSeparator(.hidden, edges: .top)
                }
                if !displayedCollections.isEmpty {
                    Section {
                        ForEach(displayedCollections) { collectionDisclosure($0) }
                    }
                    .listSectionMargins(.top, 16)
                    .listSectionMargins(.vertical, 0)
                    .listSectionSeparator(.hidden)
                }
                if !hasVisibleNotes && model.loadState != .loading && canShowEmptyState {
                    emptyState
                }
                if let footer {
                    Section {} footer: { footer }
                }
            }
        }
        .tint(.primary)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .accessibilityIdentifier("library-list")
        .animation(reduceMotion ? nil : .default, value: model.matchingNotes.map(\.id))
    }

    private var pinnedCards: [LibraryNote] {
        model.hasFilters ? [] : model.unfilteredNotes(in: .gists).filter(\.isPinned)
    }

    private var mainNotes: [LibraryNote] {
        model.matchingNotes(in: .gists).filter { model.hasFilters || !$0.isPinned }
    }

    private var hasVisibleNotes: Bool {
        !pinnedCards.isEmpty || !mainNotes.isEmpty || !displayedCollections.isEmpty
    }

    private var librarySelection: Binding<Selection?> {
        Binding(
            get: {
                guard isSidebar, let id = model.selectedNoteID else { return nil }
                return visibleSelection(for: id)
            },
            set: { selection in
                // Losing a visible row is not leaving the open document.
                guard let selection else { return }
                selectedCollection = selection.collection
                if let select = actions.select {
                    select(selection.noteID)
                } else {
                    model.selectedNoteID = selection.noteID
                }
            }
        )
    }

    private func visibleSelection(for id: String) -> Selection? {
        let candidates = [selectedCollection] + LibraryCollection.allCases.filter {
            $0 != selectedCollection
        }
        return candidates.first { isVisible(id, in: $0) }.map {
            Selection(collection: $0, noteID: id)
        }
    }

    private func isVisible(_ id: String, in collection: LibraryCollection) -> Bool {
        if collection == .gists {
            return pinnedCards.contains { $0.id == id } || mainNotes.contains { $0.id == id }
        }
        return displayedCollections.contains(collection) && expansion(for: collection).wrappedValue
            && model.matchingNotes(in: collection).contains { $0.id == id }
    }

    private var collections: Binding<Set<LibraryCollection>> {
        savedCollections ?? $localCollections
    }

    private var displayedCollections: [LibraryCollection] {
        model.secondaryCollections.filter {
            !model.hasFilters || !model.matchingNotes(in: $0).isEmpty
        }
    }

    private func expansion(for collection: LibraryCollection) -> Binding<Bool> {
        Binding(
            get: {
                model.hasFilters
                    ? !collapsedSearchCollections.contains(collection)
                    : collections.wrappedValue.contains(collection)
            },
            set: { expanded in
                if model.hasFilters {
                    if expanded { collapsedSearchCollections.remove(collection) }
                    else { collapsedSearchCollections.insert(collection) }
                } else {
                    if expanded { collections.wrappedValue.insert(collection) }
                    else { collections.wrappedValue.remove(collection) }
                }
            })
    }

    private func resetSearchDisclosures() {
        collapsedSearchCollections.removeAll()
    }

    private func collectionDisclosure(_ collection: LibraryCollection) -> some View {
        DisclosureGroup(isExpanded: expansion(for: collection)) {
            ForEach(model.matchingNotes(in: collection)) { noteRow($0, collection: collection) }
        } label: {
            // A DisclosureGroup identifier would override its child row identifiers.
            collectionLabel(collection)
                .accessibilityIdentifier("library-collection-\(collection.rawValue)")
        }
        .listRowBackground(isSidebar ? nil : Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(.vertical, dynamicTypeSize.isAccessibilitySize ? nil : 0)
    }

    private func collectionLabel(_ collection: LibraryCollection) -> some View {
        let count = model.count(in: collection)
        let countLabel = count.map {
            collection == .dailyNotes ? LibraryModel.noteCountLabel($0) : LibraryModel.gistCountLabel($0)
        }
        let countText = count.map {
            Text($0, format: .number)
                .font(.subheadline).monospacedDigit().foregroundStyle(.primary)
                .fixedSize()
                .captureFrame("library-collection-count-\(collection.rawValue)")
        }
        let title = Label(collection.title, systemImage: collection.symbol)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
            .captureFrame("library-collection-title-\(collection.rawValue)")
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: collection.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .captureFrame("library-collection-title-\(collection.rawValue)")
                    Spacer(minLength: 0)
                    countText
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        title.fixedSize(horizontal: true, vertical: true)
                        Spacer(minLength: 0)
                        countText
                    }
                    VStack(alignment: .leading, spacing: headingCountSpacing) {
                        title
                        countText
                    }
                }
            }
        }
        .font(.headline)
        .foregroundStyle(.primary)
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 44,
            alignment: .leading)
        .textCase(nil)
        .captureFrame("library-collection-\(collection.rawValue)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: collection.title))
        .accessibilityValue(Text(verbatim: countLabel ?? ""))
        .accessibilityAddTraits(.isHeader)
    }

    private var remoteStatus: GitHubStatusState {
        let state = model.gitHubStatus
            ?? (model.loadState == .loading
                ? .checking(operation: String(localized: "Updating from GitHub", bundle: .module))
                : .idle)
        if isPullRefreshing, case .checking = state { return .idle }
        return state
    }

    private var searchScope: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(String(localized: "All Notes", bundle: .module), systemImage: "doc.text")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button(String(localized: "Clear", bundle: .module)) { model.clearFilters() }
                        .tint(.primary)
                        .font(.subheadline)
                }
                if !model.selectedTagIDs.isEmpty {
                    TagLabels(
                        tags: model.snapshot.tags.filter { model.selectedTagIDs.contains($0.id) },
                        isSelected: true
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var searchSummary: some View {
        let coverage: LibrarySearchCoverage? = if case .results(_, let coverage) = model.searchState {
            coverage
        } else {
            nil
        }
        return SearchSummary(coverage: coverage, selectedTagCount: model.selectedTagIDs.count)
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
        case .inactive, .results:
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
        }
    }

    @ViewBuilder
    private var status: some View {
        if !model.snapshot.notes.isEmpty, case .problem = remoteStatus {
            EmptyView()
        } else {
        switch model.loadState {
        case .loading:
            EmptyView()
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
                .tint(.primary)
            }
        case .reconnectRequired(let message):
            Section {
                Label(String(localized: "Reconnect GitHub", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    if let reconnect = actions.reconnect {
                        Button(String(localized: "Continue with GitHub", bundle: .module), action: reconnect)
                            .tint(.primary)
                }
            }
        case .signedOut, .ready:
            EmptyView()
        }
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
                Button(action: reconnect) {
                    Text("Continue with GitHub", bundle: .module)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .tint(Color(uiColor: .label))
                    .accessibilityIdentifier("library-sign-in")
            }
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                if !model.hasFilters {
                    NotebookArtwork()
                    Text("A notebook of your own", bundle: .module)
                        .font(.title2.weight(.semibold))
                } else {
                    Label(
                        String(localized: "No matching notes", bundle: .module),
                        systemImage: "magnifyingglass"
                    )
                }
            } description: {
                if model.hasFilters {
                    Text("Try another search or clear your filters.", bundle: .module)
                } else {
                    Text("A thought, a list, a little thing worth keeping. Start with your first note.", bundle: .module)
                }
            } actions: {
                if model.hasFilters {
                    Button(String(localized: "Clear filters", bundle: .module)) { model.clearFilters() }
                        .tint(.primary)
                } else {
                    Button(action: actions.create) {
                        Text("Create a note", bundle: .module)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(uiColor: .label))
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func noteRow(
        _ note: LibraryNote, collection: LibraryCollection = .gists, isCard: Bool = false,
        hidesTopSeparator: Bool = false
    ) -> some View {
        let selection = Selection(collection: collection, noteID: note.id)
        let openComments: (@MainActor (String) -> Void)? = actions.openComments.map { action in
            { @MainActor (id: String) in
                selectedCollection = collection
                action(id)
            }
        }
        let delete: (@MainActor () -> Void)? = actions.deletionAction(for: note).map { action in
            { @MainActor in
                deletionSelection = selection
                action()
            }
        }
        return NavigationLink(value: selection) {
            if isCard {
                LibraryPinnedCard(
                    note: note, tags: model.tags(for: note),
                    isSelected: librarySelection.wrappedValue == selection,
                    isSidebar: isSidebar)
            } else {
                LibraryNoteRow(
                    note: note, tags: model.tags(for: note),
                    showsStar: collection != .starred)
            }
        }
        .accessibilityIdentifier("\(isCard ? "library-featured" : "library-note")-\(note.id)")
        .navigationLinkIndicatorVisibility(.hidden)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .listRowInsets(EdgeInsets(
            top: isCard ? 4 : 0, leading: isCard ? 0 : 12,
            bottom: isCard ? 4 : 0, trailing: isCard ? 0 : 12))
        .listRowSeparator(isCard || hidesTopSeparator ? .hidden : .visible, edges: .top)
        .listRowSeparator(isCard ? .hidden : .visible, edges: .bottom)
        .listRowSeparatorTint(Color(uiColor: .separator))
        .listRowBackground(isCard || !isSidebar ? Color.clear : nil)
        .contextMenu { rowActions(note, openComments: openComments, delete: delete) }
        .modifier(LibraryCommentsAccessibilityAction(note: note, action: openComments))
        .modifier(LibraryRowDeletionConfirmation(
            rowID: note.id, target: deletionConfirmation(for: selection)))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let delete {
                // The confirmation owns the destructive role, not this pending swipe.
                Button(String(localized: "Delete", bundle: .module), systemImage: "trash", action: delete)
                    .tint(.red)
            }
            if note.isOwned, !note.isRecovery, let archive = actions.toggleArchive {
                Button {
                    archive(note.id)
                } label: {
                    Label(
                        note.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                        systemImage: "archivebox"
                    )
                }
                .tint(Color(uiColor: .darkGray))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if note.isOwned, !note.isRecovery, let pin = actions.togglePin {
                Button {
                    pin(note.id)
                } label: {
                    Label(
                        note.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                        systemImage: note.isPinned ? "pin.slash" : "pin"
                    )
                }
                .tint(Color(uiColor: .darkGray))
            }
        }
    }

    private func deletionConfirmation(for selection: Selection) -> LibraryDeletionConfirmation? {
        guard let target = actions.deletionConfirmation else { return nil }
        let source = deletionSelection.flatMap { $0.noteID == target.rowID ? $0 : nil }
            ?? visibleSelection(for: target.rowID)
        return source == selection ? target : nil
    }

    @ViewBuilder
    private func rowActions(
        _ note: LibraryNote, openComments: (@MainActor (String) -> Void)?,
        delete: (@MainActor () -> Void)?
    ) -> some View {
        if note.supportsComments, let openComments {
            Button(
                String(localized: "Open Comments", bundle: .module), systemImage: "text.bubble"
            ) { openComments(note.id) }
        }
        if note.isOwned, !note.isRecovery, let pin = actions.togglePin {
            Button(
                note.isPinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
                systemImage: note.isPinned ? "pin.slash" : "pin"
            ) { pin(note.id) }
        }
        if note.isOwned, !note.isRecovery, let archive = actions.toggleArchive {
            Button(
                note.isArchived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                systemImage: "archivebox"
            ) { archive(note.id) }
        }
        if let delete {
            Divider()
            Button(
                String(localized: "Delete", bundle: .module), systemImage: "trash",
                role: .destructive, action: delete)
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if model.loadState != .signedOut {
            if isSidebar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            if !(containerSearchPresentation?.wrappedValue ?? searchPresented) {
                if isGitHubStatusVisible, case .problem = remoteStatus {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        GitHubStatusControl(state: remoteStatus) {
                            if let recover = actions.recoverStatus {
                                recover()
                            } else if case .reconnectRequired = model.loadState,
                                      let reconnect = actions.reconnect {
                                reconnect()
                            } else {
                                Task { await actions.refresh() }
                            }
                        }
                    }
                    .axisBehavior(.verticalPreferred)
                    .sharedBackgroundVisibility(.hidden)
                }
                if !isSidebar {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        tagFilterButton
                            .labelStyle(.iconOnly)
                    }
                }
            }
            if !isSidebar {
                ToolbarItemGroup(placement: .primaryAction) {
                    LibraryCreateButton(action: actions.create)
                    LibraryTodayButton(
                        summary: model.today, isSelected: isTodaySelected, action: actions.today)
                    if let account = actions.account {
                        settingsButton(account)
                    }
                }
            }
            if isSidebar {
                ToolbarItem(placement: .secondaryAction) {
                    tagFilterButton
                }
            }
        }
        if isSidebar || model.loadState == .signedOut, let account = actions.account {
            ToolbarItem(placement: .secondaryAction) {
                settingsButton(account)
            }
        }
    }

    private func settingsButton(_ action: @escaping @MainActor () -> Void) -> some View {
        Button(String(localized: "Settings", bundle: .module), systemImage: "gearshape", action: action)
            .tint(.primary)
            .accessibilityIdentifier("library-settings")
    }

    private var tagFilterButton: some View {
        Button {
            showingTags = true
        } label: {
            Label {
                if isSidebar {
                    Text("Filter by tags", bundle: .module)
                } else {
                    Text("Filter by tags, \(model.selectedTagIDs.count) selected", bundle: .module)
                }
            } icon: {
                Image(systemName: model.selectedTagIDs.isEmpty ? "tag" : "tag.fill")
            }
            .frame(minWidth: isSidebar ? nil : 44, minHeight: isSidebar ? nil : 44)
            .contentShape(.rect)
        }
        .disabled(model.snapshot.tags.isEmpty)
        .tint(.primary)
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
                                if model.selectedTagIDs.contains(tag.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.primary)
                                        .transition(.opacity)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selectedTagIDs.contains(tag.id) ? .isSelected : [])
                        .accessibilityIdentifier("library-tag-filter-\(tag.id)")
                        .captureFrame("library-tag-filter-\(tag.id)")
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
                    .tint(.primary)
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
                        .tint(.primary)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("library-tag-filter-done")
                        .captureFrame("library-tag-filter-done")
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
