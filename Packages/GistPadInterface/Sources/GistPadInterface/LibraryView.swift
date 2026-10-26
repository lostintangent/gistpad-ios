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

    public func libraryCreateAction(
        isVisible: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        toolbar {
            if isVisible {
                ToolbarItem(placement: .primaryAction) {
                    LibraryCreateButton(action: action)
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
    func deletionAction(for note: LibraryNote) -> (() -> Void)? {
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
    private enum Selection: Hashable {
        case today
        case note(String)
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
    @State private var showingTags = false
    @State private var tagQuery = ""
    @State private var isPullRefreshing = false
    @State private var searchPresented = false
    @State private var windowContentWidth: CGFloat?
    @ScaledMetric(relativeTo: .body) private var headingTopSpacing = 32
    @ScaledMetric(relativeTo: .body) private var headingBottomSpacing = 12
    @ScaledMetric(relativeTo: .body) private var headingCountSpacing = 4
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.librarySearchManagedByContainer) private var searchManagedByContainer
    @Environment(\.librarySearchPresentation) private var containerSearchPresentation
    @Environment(\.isGitHubStatusVisible) private var isGitHubStatusVisible

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
    }

    @ViewBuilder
    private var navigationList: some View {
        if model.loadState == .signedOut {
            signedOutInvitation
        } else if searchManagedByContainer || !isSidebar {
            adaptiveList
                .toolbarTitleMenu { collectionPicker }
        } else {
            adaptiveList
                .searchable(
                    text: $model.query, isPresented: $searchPresented,
                    placement: .sidebar,
                    prompt: Text("Search notes", bundle: .module))
                .searchToolbarBehavior(isSidebar ? .minimize : .automatic)
                .toolbarTitleMenu { collectionPicker }
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
        return model.collection == .gists ? String(localized: "GistPad", bundle: .module) : model.collection.title
    }

    private var navigationSubtitle: String {
        guard model.loadState != .signedOut else { return "" }
        if model.collection == .dailyNotes {
            return model.dailyNoteCount.map(LibraryModel.noteCountLabel) ?? ""
        }
        return model.collectionGistCount.map(LibraryModel.gistCountLabel) ?? ""
    }

    private var libraryList: some View {
        List(selection: librarySelection) {
            status
            if model.loadState != .signedOut {
                if model.showsFeaturedNotes {
                    Section {
                        if isSidebar {
                            NavigationLink(value: Selection.today) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "calendar")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                        .captureFrame("library-today-symbol")
                                    LibraryNoteRow(
                                        note: .init(
                                            id: "today", title: String(localized: "Today", bundle: .module),
                                            updatedAt: model.today.date, isDailyNote: true,
                                            excerpt: model.today.excerpt,
                                            progress: model.today.availability == .missing ? nil : model.today.progress),
                                        tags: [])
                                }
                                .frame(minHeight: 44)
                            }
                            .tint(.primary)
                            .navigationLinkIndicatorVisibility(.hidden)
                            .tag(Selection.today)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
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
                    .listSectionMargins(.vertical, 0)
                    .listSectionMargins(.top, headingTopSpacing / 2)
                    .listSectionSeparator(.hidden)
                }
                if model.showsSearchScope {
                    searchScope
                }
                searchStatus
                if !model.featuredNotes.isEmpty {
                    Section {
                        pinnedNotes
                    } header: {
                        pinnedHeading
                            .listRowInsets(
                                isSidebar ? EdgeInsets()
                                    : EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    }
                    .listSectionMargins(.vertical, 0)
                    .listSectionSeparator(.visible, edges: .top)
                }
                if !model.listedNotes.isEmpty {
                    listedNotesSection
                        .listSectionMargins(.vertical, 0)
                        .listSectionSeparator(.visible, edges: .top)
                }
                if model.matchingNotes.isEmpty && model.loadState != .loading && canShowEmptyState {
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

    @ViewBuilder
    private var listedNotesSection: some View {
        if model.showsListedNotesHeading {
            Section {
                listedNoteRows
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    if model.hasFilters { searchSummary }
                    sectionHeading(
                        model.hasFilters ? String(localized: "Results", bundle: .module) : model.collection.title,
                        symbol: !model.hasFilters && model.collection == .gists ? "doc.text" : nil,
                        count: model.hasFilters ? model.resultGistCount
                            : model.hasKnownGistSnapshot ? LibraryModel.gistCount(in: model.listedNotes) : nil)
                    .accessibilityIdentifier("library-listed-heading")
                }
                .listRowInsets(
                    isSidebar ? EdgeInsets()
                        : EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        } else {
            Section {
                listedNoteRows
            }
        }
    }

    private var listedNoteRows: some View {
        ForEach(model.listedNotes) { noteRow($0) }
    }

    private var librarySelection: Binding<Selection?> {
        Binding(
            get: {
                guard isSidebar else { return nil }
                if isTodaySelected { return model.showsFeaturedNotes ? .today : nil }
                return model.visibleSelectedNoteID.map(Selection.note)
            },
            set: { selection in
                switch selection {
                case .today:
                    actions.today()
                case .note(let id):
                    if let select = actions.select {
                        select(id)
                    } else {
                        model.selectedNoteID = id
                    }
                case nil:
                    // Losing a visible row is not leaving the open document.
                    break
                }
            }
        )
    }

    private func sectionHeading(
        _ title: String, symbol: String? = nil, count: Int? = nil
    ) -> some View {
        Group {
            if let count {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        headingLabel(title, symbol: symbol)
                            .fixedSize(horizontal: true, vertical: true)
                        Spacer(minLength: 12)
                        headingCount(count)
                            .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: headingCountSpacing) {
                        headingLabel(title, symbol: symbol)
                        headingCount(count)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                headingLabel(title, symbol: symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.title2.weight(.bold))
        .foregroundStyle(Color(uiColor: .label))
        .textCase(nil)
        .captureFrame("library-heading-\(symbol ?? "scope")")
        .padding(.horizontal, 12)
        .padding(.top, headingTopSpacing)
        .padding(.bottom, headingBottomSpacing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            count.map { Text("\(title), \(LibraryModel.gistCountLabel($0))", bundle: .module) }
                ?? Text(verbatim: title))
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func headingLabel(_ title: String, symbol: String?) -> some View {
        if let symbol {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        } else {
            Text(verbatim: title)
        }
    }

    private func headingCount(_ count: Int) -> some View {
        Text(count, format: .number)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var pinnedHeading: some View {
        sectionHeading(
            String(localized: "Pinned Gists", bundle: .module), symbol: "pin.fill",
            count: model.hasKnownGistSnapshot ? LibraryModel.gistCount(in: model.featuredNotes) : nil)
        .accessibilityIdentifier("library-pinned-heading")
    }

    private var remoteStatus: GitHubStatusState {
        let state = model.gitHubStatus
            ?? (model.loadState == .loading
                ? .checking(operation: String(localized: "Updating from GitHub", bundle: .module))
                : .idle)
        if isPullRefreshing, case .checking = state { return .idle }
        return state
    }

    private var pinnedNotes: some View {
        ForEach(model.featuredNotes) { note in
            noteRow(note, showsPin: false, isFeatured: true)
        }
    }

    private var searchScope: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.collection.title, systemImage: model.collection.symbol)
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
                if model.collection != .gists {
                    Button(String(localized: "Search All Notes", bundle: .module)) {
                        model.collection = .gists
                    }
                    .tint(.primary)
                    .font(.subheadline)
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
                    Text("Try another search or clear your filters.", bundle: .module)
                } else {
                    Text(verbatim: emptyDescription)
                }
            } actions: {
                if model.hasFilters {
                    Button(String(localized: "Clear filters", bundle: .module)) { model.clearFilters() }
                        .tint(.primary)
                } else if model.collection == .gists {
                    Button(action: actions.create) {
                        Text("Create a note", bundle: .module)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(uiColor: .label))
                } else if model.collection == .dailyNotes {
                    Button(action: actions.today) {
                        Text("Start today's note", bundle: .module)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(uiColor: .label))
                }
            }
        } header: {
            if model.hasFilters { searchSummary }
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

    private func noteRow(
        _ note: LibraryNote, showsPin: Bool = true, isFeatured: Bool = false
    ) -> some View {
        NavigationLink(value: Selection.note(note.id)) {
            LibraryNoteRow(
                note: note, tags: model.tags(for: note), showsPin: showsPin,
                showsStar: model.collection != .starred)
        }
        .accessibilityIdentifier("\(isFeatured ? "library-featured" : "library-note")-\(note.id)")
        .navigationLinkIndicatorVisibility(.hidden)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color(uiColor: .separator))
        .listRowBackground(isSidebar ? nil : Color.clear)
        .contextMenu { rowActions(note) }
        .modifier(LibraryCommentsAccessibilityAction(note: note, action: actions.openComments))
        .modifier(LibraryRowDeletionConfirmation(rowID: note.id, target: actions.deletionConfirmation))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let delete = actions.deletionAction(for: note) {
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

    @ViewBuilder
    private func rowActions(_ note: LibraryNote) -> some View {
        if note.supportsComments, let openComments = actions.openComments {
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
        if let delete = actions.deletionAction(for: note) {
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

    private var collectionPicker: some View {
        Picker(String(localized: "Collection", bundle: .module), selection: $model.collection) {
            ForEach(model.visibleCollections) { collection in
                Label(
                    collection == .gists ? String(localized: "All Notes", bundle: .module) : collection.title,
                    systemImage: collection.symbol
                )
                .tag(collection)
            }
        }
        .tint(.primary)
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
