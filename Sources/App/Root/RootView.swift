import AppIntents
import Comments
import Editor
import Screens
import Model
import Observation
import Platform
import SwiftUI
import Store

struct RootView: View {
    @Bindable var model: GistPadModel
    private let pending: PendingLink
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var sheet: Sheet?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var allowsSplit = false
    @State private var layout: LayoutPreferences
    @State private var intelligence = IntelligencePresentation()
    @State private var comments: CommentsPresentation
    @State private var images: ImageUpload
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    init(
        model: GistPadModel, layout: LayoutPreferences = LayoutPreferences(),
        pending: PendingLink = .shared
    ) {
        self.model = model
        self.pending = pending
        _layout = State(initialValue: layout)
        _comments = State(initialValue: CommentsPresentation(app: model))
        _images = State(initialValue: ImageUpload(model: model))
    }

    private var active: GistFileEditor? { model.activeEditor }

    private var librarySections: Binding<Set<LibrarySection>> {
        guard let accountID = model.account?.id else { return .constant([]) }
        return Binding(
            get: { layout.expandedSections(accountID: accountID) },
            set: { layout.setExpandedSections($0, accountID: accountID) })
    }

    private var pinnedExpanded: Binding<Bool> {
        guard let accountID = model.account?.id else { return .constant(true) }
        return Binding(
            get: { layout.isPinnedExpanded(accountID: accountID) },
            set: { layout.setPinnedExpanded($0, accountID: accountID) })
    }

    /// GistPad's navigation, following the links that arrive, the app coming and going and the
    /// account that's signed in, under one alert and one sheet.
    var body: some View {
        navigation
            .task {
                await model.start()
                await model.returnToApp()
            }
            .task(id: linkToOpen) { await openPendingLink() }
            #if DEBUG
            .onChange(of: pending.link) { presentFixtureSheet() }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { leaveApp() }
                if phase == .active { Task { await model.returnToApp() } }
            }
            .onChange(of: settledAccountID) {
                comments.reset()
                intelligence.target = nil
            }
            .onChange(of: model.account?.id) {
                columnVisibility = .all
                sheet = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                model.updateCalendar()
            }
            .alert(error: $model.failure) {
                if model.failure?.action == .reconnect {
                    Button(role: .cancel) {}
                    Button(Failure.Action.reconnect.title) { Task { await model.reconnect() } }
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .settings: settingsSheet
                case .addToToday: AddToTodaySheet()
                case .tags(let target): TagEditor(target, model: model)
                case .rename(let target): RenameSheet(target, model: model)
                case .review(let target):
                    ConflictReview(fileEditor: target.fileEditor, review: target.review)
                }
            }
            .intelligenceSheet(intelligence)
    }

    /// The library and the open file, preparing each file as it arrives and leaving it as it goes.
    private var navigation: some View {
        Group {
            if model.account == nil {
                NavigationStack {
                    library
                }
            } else {
                splitView
            }
        }
        .background {
            // Platform gap: SwiftUI drops onChange actions past a few per frame, and a launch link can
            // restore, open and present notes in one. Remove this keyed view when onChange runs for each.
            Color.clear.onAppear(perform: didActivate).id(active?.editor.id)
        }
        .onChange(of: active?.file.id) { previous, _ in
            if let previous, let outgoing = model.editors[previous] {
                Task { await outgoing.leave() }
            }
        }
        .onChange(of: model.state.selectedID) { _, selected in
            if selected == nil, model.opening == nil { compactColumn = .sidebar }
        }
        .onChange(of: compactColumn) { previous, current in
            guard previous != current, current == .sidebar else { return }
            if horizontalSizeClass == .compact {
                comments.hide()
                model.showLibrary()
                active?.editor.endEditing()
            }
            if let outgoing = active { Task { await outgoing.leave() } }
        }
    }

    /// Signed out once launch knows there's no account, so the list doesn't flash the invitation.
    private var isSignedOut: Bool { model.account == nil && model.phase != .loading }

    private var isLoadingLibrary: Bool { model.phase == .loading || model.phase == .refreshing }

    private var library: some View {
        LibraryView(
            state: model.state, actions: libraryActions, isSidebar: horizontalSizeClass == .regular,
            isSignedOut: isSignedOut, isLoading: isLoadingLibrary, status: model.refreshStatus,
            expandedSections: librarySections, isPinnedExpanded: pinnedExpanded
        )
        .id(model.account?.id)
    }

    private var splitView: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn
        ) {
            library
        } detail: {
            NavigationStack {
                ZStack {
                    if let opening = model.opening, let failure = opening.failure {
                        OpenFailedView(gist: opening.details, failure: failure) {
                            Task {
                                if failure.action == .reconnect { await model.reconnect() }
                                await model.open(opening.request)
                            }
                        }
                    } else if let details = model.opening?.details ?? active?.details {
                        gistScreen(details)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // No trait says whether two panes fit beside the sidebar, so the column reports it.
                .onGeometryChange(for: Bool.self) {
                    LayoutPreferences.allowsSplit(availableWidth: $0.size.width)
                } action: { allows in
                    allowsSplit = allows
                    // An edit that loses Split's room stays in Edit rather than falling back to Preview.
                    if !allows, layout.preferredMode == .split, let active, active.editor.isEditing {
                        active.mode = .edit
                    }
                }
                .libraryRail(
                    isVisible: horizontalSizeClass == .regular && !isSignedOut,
                    today: model.state.today,
                    create: libraryActions.create, openToday: libraryActions.today)
            }
            .frame(minWidth: comments.isPresented && horizontalSizeClass == .regular ? 320 : 0)
        }
        .navigationSplitViewStyle(.balanced)
        .commentsInspector(comments, active: active, columnVisibility: $columnVisibility)
    }

    /// Prepares a file as it comes into the detail column.
    private func didActivate() {
        guard let active else { return }
        // A new gist or day already asked for the caret, so it stays in Edit.
        if !active.editor.isEditing, !active.editor.isFocusPending {
            active.mode = layout.initialMode(isUnpublished: active.file.isNew)
        }
        comments.activate(active)
        openRequestedComments()
        // A completed restoration must not reopen detail after returning to Library.
        if model.state.selectedID != nil {
            compactColumn = .detail
        }
        #if DEBUG
        presentFixtureSheet()
        #endif
    }

    /// Opens the comments a library row asked for, once its file is the active one.
    private func openRequestedComments() {
        guard let active, comments.requestedRowID == model.state.selectedID,
            comments.editorID == active.editor.id
        else { return }
        comments.requestedRowID = nil
        comments.open(for: active)
    }

    /// The account whose gists are up, or nil while one signs in, out or waits to replace it.
    private var settledAccountID: UUID? {
        model.phase.isChangingAccount ? nil : model.account?.id
    }

    /// The one sheet over the app. A link or another account replaces it.
    enum Sheet: Identifiable {
        case settings, addToToday
        case tags(TagTarget)
        case rename(RenameTarget)
        case review(ConflictTarget)

        var id: String {
            switch self {
            case .settings: "settings"
            case .addToToday: "addToToday"
            case .tags(let target): "tags/\(target.id)"
            case .rename(let target): "rename/\(target.id)"
            case .review(let target): "review/\(target.id)"
            }
        }
    }

    private var settingsSheet: some View {
        let account = model.account
        return SettingsSheet(
            account: account,
            savePreference: { key, value in
                try await model.updatePreferences([.setBoolean(key, value)])
            },
            connect: {
                sheet = nil
                Task { await model.reconnect() }
            },
            signOut: { try await model.signOut() }
        ) {
            AccentColorRow(savedHex: account?.preferences.accentColor) { hex in
                try await model.updatePreferences([.setAccentColor(hex)])
            }
        }
        .id(account?.id)
    }

    private var libraryActions: LibraryActions {
        LibraryActions(
            model: model, undoManager: undoManager,
            select: { selectRow($0) }, openComments: { openComments(rowID: $0) },
            today: { openToday() }, settings: { sheet = .settings })
    }

    private func entityIdentifier(for fileEditor: GistFileEditor) -> EntityIdentifier? {
        onScreenNote(for: fileEditor).map {
            EntityIdentifier(for: GistFileEntity.self, identifier: $0.url.absoluteString)
        }
    }

    private func onScreenNote(for fileEditor: GistFileEditor) -> GistPadLink? {
        guard scenePhase == .active,
            horizontalSizeClass != .compact || compactColumn == .detail,
            model.state.selectedID != nil, sheet == nil,
            model.account?.id == fileEditor.file.accountID,
            !fileEditor.file.isDeletedOnGitHub
        else { return nil }
        if let gist = fileEditor.file.gist {
            return .gist(id: gist.id, filename: fileEditor.file.filename)
        }
        guard fileEditor.file.gistID == nil else { return nil }
        return .unpublishedGist(accountID: fileEditor.file.accountID, draftID: fileEditor.file.id)
    }

    /// The file in the detail column, under its bar from the moment it's asked for, so the push
    /// brings the bar in with it. Only the content waits for the file.
    private func gistScreen(_ details: GistDetails) -> some View {
        let showsComments = comments.isPresented && active.map { comments.matches($0.file) } == true
        let mode = Binding(
            get: {
                if showsComments { return comments.fileMode }
                return layout.presentedMode(
                    allowsSplit: allowsSplit,
                    sessionMode: active?.mode
                        ?? layout.initialMode(isUnpublished: model.opening?.isPublished == false),
                    isEditing: active?.editor.isEditing == true, canEdit: details.isOwned)
            },
            set: {
                // The keyboard starts down first, so the page appears at rest instead of inside its animation.
                if $0 == .preview { active?.editor.endEditing() }
                if showsComments {
                    comments.fileMode = $0
                } else {
                    layout.select($0)
                    if $0 != .split { active?.mode = $0 }
                }
            })
        var details = details
        if let active, comments.matches(active.file) {
            details.commentCount = comments.model?.comments?.count ?? details.commentCount
        }
        return GistScreen(
            gist: details, mode: mode, status: active?.status ?? .published,
            actions: active.map(gistActions) ?? GistActions(opening: model.opening, comments: comments),
            allowsSplit: !comments.isPresented && allowsSplit, areCommentsPresented: showsComments
        ) {
            if let active { source(active) }
        } preview: {
            if let active { preview(active) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { model.opening.map { OpeningProgress(title: $0.details.title) } }
        .background { active.map { session($0).id($0.editor.id) } }
        .imagePicker(images)
    }

    /// What an open file keeps up while it's on screen: its refresh from GitHub and its comments,
    /// its status in the bottom bar, and the note Siri and Spotlight see.
    private func session(_ fileEditor: GistFileEditor) -> some View {
        let identifier = entityIdentifier(for: fileEditor)
        return Color.clear
            .toolbar {
                if fileEditor.refreshStatus != .idle {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        GitHubStatusControl(status: fileEditor.refreshStatus) {
                            Task {
                                if fileEditor.refreshFailure?.action == .reconnect { await model.reconnect() }
                                await fileEditor.refresh()
                            }
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .userActivity("dev.gistpad.GistPad.note", isActive: identifier != nil) { activity in
                activity.title = fileEditor.details.title
                activity.isEligibleForSearch = false
                activity.isEligibleForHandoff = false
                activity.appEntityIdentifier = identifier
            }
            .onChange(of: identifier, initial: true) { fileEditor.editor.entityIdentifier = $1 }
            .onDisappear { fileEditor.editor.entityIdentifier = nil }
            .task { await fileEditor.refresh() }
            .task(id: comments.tracking(fileEditor)) { await comments.track(fileEditor) }
    }

    private func source(_ fileEditor: GistFileEditor) -> some View {
        let highlights = comments.highlights(for: fileEditor, origin: .edit)
        return EditorView(
            editor: fileEditor.editor, title: fileEditor.details.title,
            insertImage: images.canChooseImage(for: fileEditor)
                ? { @MainActor in comments.performAfterClosing { images.chooseImage(for: fileEditor) } }
                : nil,
            intelligence: { comments.performAfterClosing { presentIntelligence(fileEditor) } },
            comments: highlights.configuration, commentActions: highlights.actions)
    }

    private func preview(_ fileEditor: GistFileEditor) -> some View {
        let highlights = comments.highlights(for: fileEditor, origin: .preview)
        return FilePreview(
            editor: fileEditor.editor, allowsMutations: fileEditor.details.isOwned,
            comments: highlights.configuration, commentActions: highlights.actions,
            openWikilink: { target in
                if let gist = model.state.gists.first(where: {
                    $0.title.localizedStandardCompare(target) == .orderedSame
                }) {
                    Task { await model.open(.gist(id: gist.id)) }
                } else {
                    model.failure = Failure(String(localized: "No gist has that title."))
                }
            })
            .id(fileEditor.editor.id)
            .appEntityIdentifier(entityIdentifier(for: fileEditor))
    }

    private func gistActions(_ fileEditor: GistFileEditor) -> GistActions {
        GistActions(
            fileEditor, model: model, comments: comments, undoManager: undoManager,
            present: { sheet = $0 }, intelligence: { presentIntelligence(fileEditor) })
    }

    private func selectRow(_ id: String) {
        model.open(rowID: id)
        compactColumn = .detail
    }

    private func openComments(rowID: String) {
        comments.requestedRowID = rowID
        selectRow(rowID)
        openRequestedComments()
    }

    private func presentIntelligence(_ fileEditor: GistFileEditor) {
        intelligence.present(fileEditor, model: model) { layout.select(.edit) }
    }

    private func openToday() {
        compactColumn = .detail
        let target = DailyNote.Day()
        Task { await model.open(.today(target)) }
    }

    /// The pending link, once the account it opens in has settled.
    private var linkToOpen: GistPadLink? {
        guard model.phase != .loading, model.phase != .signingIn else { return nil }
        return pending.link
    }

    #if DEBUG
    /// Presents a fixture launch's `--sheet` once its file is open and activated. The link can
    /// clear before the file it opened activates, and Comments only opens for the activated file.
    private func presentFixtureSheet() {
        guard let fixtureSheet = FixtureLaunch.pendingSheet, pending.link == nil, let active,
            comments.editorID == active.editor.id
        else { return }
        FixtureLaunch.pendingSheet = nil
        let actions = gistActions(active)
        switch fixtureSheet {
        case .settings: sheet = .settings
        case .tags: actions.tags?()
        case .intelligence: actions.intelligence()
        case .comments: actions.comments?()
        case .today: break
        }
    }
    #endif

    /// Opens a widget, Shortcut or Spotlight link in place of whatever was showing.
    private func openPendingLink() async {
        guard let link = linkToOpen, let account = model.account else { return }
        sheet = nil
        intelligence.target = nil
        model.failure = nil
        switch link {
        case .today:
            // Like the Today button, a folded phone shows Today while it's staged.
            compactColumn = .detail
            await model.open(.today())
        case .addToToday:
            sheet = .addToToday
        case .newGist:
            await model.open(.new)
        case .gist(let id, let filename):
            await model.open(.gist(id: id, filename: filename))
        case .unpublishedGist(let accountID, let draftID):
            guard accountID == account.id else {
                model.failure = Failure(
                    String(localized: "This draft belongs to another GitHub account. Sign out, then sign in with that account to open it."))
                pending.link = nil
                return
            }
            await model.open(.draft(id: draftID))
        }
        guard !Task.isCancelled, pending.link == link else { return }
        if model.activeEditor != nil || model.opening?.failure != nil {
            compactColumn = .detail
        }
        pending.link = nil
    }

    private func leaveApp() {
        let lease = BackgroundLease()
        let publishing = Task {
            await model.leaveApp(shouldContinue: { lease.isActive })
            lease.end()
        }
        lease.onExpiration = { publishing.cancel() }
    }
}
