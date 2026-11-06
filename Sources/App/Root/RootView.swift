import AppIntents
import Comments
import Editor
import Interface
import Notebook
import Observation
import OSLog
import Platform
import SwiftUI
import Sync

struct RootView: View {
  @Bindable var library: Library
  private let pending: PendingLink
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var sheet: Sheet?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var layout = LayoutPreferences()
  @State private var intelligence = IntelligencePresentation()
  @State private var comments: CommentsPresentation
  @State private var images: ImageUpload
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.openURL) private var openURL
  @Environment(\.undoManager) private var undoManager
  @Environment(\.scenePhase) private var scenePhase

  init(
    library: Library, layout: LayoutPreferences = LayoutPreferences(),
    pending: PendingLink = .shared
  ) {
    self.library = library
    self.pending = pending
    _layout = State(initialValue: layout)
    _comments = State(initialValue: CommentsPresentation(library: library))
    _images = State(initialValue: ImageUpload(upload: library.uploadImage))
  }

  private var active: FileSession? { library.activeSession }

  private var librarySections: Binding<Set<LibrarySection>> {
    guard let accountID = library.account?.id else { return .constant([]) }
    return Binding(
      get: { layout.expandedSections(accountID: accountID) },
      set: { layout.setExpandedSections($0, accountID: accountID) })
  }

  private var pinnedExpanded: Binding<Bool> {
    guard let accountID = library.account?.id else { return .constant(true) }
    return Binding(
      get: { layout.isPinnedExpanded(accountID: accountID) },
      set: { layout.setPinnedExpanded($0, accountID: accountID) })
  }

  var body: some View {
    workspaceSheets
      .sheet(isPresented: accountSwitchPresented) {
        accountSwitchSheet
      }
      .intelligenceSheet(intelligence)
  }

  private var navigation: some View {
    Group {
      if library.account == nil {
        NavigationStack {
          LibraryView(
            state: library.state, actions: libraryActions, isSidebar: horizontalSizeClass == .regular,
            expandedSections: librarySections, isPinnedExpanded: pinnedExpanded)
        }
      } else {
        splitView
      }
    }
  }

  private var libraryProblem: GitHubStatusProblem? {
    if case .problem(let problem) = library.remoteRefreshStatus { problem } else { nil }
  }

  private var splitView: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn
    ) {
      LibraryView(
        state: library.state, actions: libraryActions,
        isSidebar: horizontalSizeClass == .regular,
        problem: libraryProblem,
        expandedSections: librarySections,
        isPinnedExpanded: pinnedExpanded)
        .id(library.account?.id)
    } detail: {
      NavigationStack {
        GeometryReader { geometry in
          if let opening = library.opening, let failure = opening.failure {
            OpenFailedView(opening: opening, message: failure) {
              Task { await library.open(opening.request) }
            }
          } else if let active {
            fileScreen(active, availableWidth: geometry.size.width)
          } else if let file = library.visibleFile {
            OpeningFileView(title: library.details(for: file).title, file: file)
              .id(file.id)
          } else if let title = library.openingTitle {
            OpeningFileView(title: title)
              .id(library.opening?.rowID ?? library.state.selectedID)
          }
        }
        .libraryRail(
          isVisible: horizontalSizeClass == .regular && library.state.loadState != .signedOut,
          today: library.state.today,
          create: libraryActions.create, openToday: libraryActions.today)
      }
      .frame(minWidth: comments.isPresented && horizontalSizeClass == .regular ? 320 : 0)
    }
    .navigationSplitViewStyle(.balanced)
    .commentsInspector(comments, active: active, columnVisibility: $columnVisibility)
  }

  private var workspaceNavigationLifecycle: some View {
    navigation
    .task {
      await library.start()
      await library.publishDrafts()
    }
    .task(id: linkToOpen) { await openPendingLink() }
    #if DEBUG
    .onChange(of: pending.link) { presentFixtureSheet() }
    #endif
    .background {
      // Keyed by activation instead of onChange, because SwiftUI drops onChange actions past a
      // few per frame. A launch link can restore today, open, and present a new note in one.
      Color.clear.onAppear(perform: didActivate).id(active?.file.activationID)
    }
    .onChange(of: active?.draft.id) { previous, _ in
      if let previous, let outgoing = library.sessions[previous] {
        Task { await outgoing.leave() }
      }
    }
    .onChange(of: library.state.selectedID) { _, selected in
      if selected == nil, library.opening == nil { compactColumn = .sidebar }
    }
    .onChange(of: compactColumn) { previous, current in
      guard previous != current, current == .sidebar else { return }
      if horizontalSizeClass == .compact {
        comments.hide()
        library.showLibrary()
        active?.editor.textView.resignFirstResponder()
      }
      if let outgoing = active { Task { await outgoing.leave() } }
    }
  }

  /// Prepares a file as it comes into the detail column.
  private func didActivate() {
    guard let active else { return }
    active.mode = layout.initialMode(isUnpublished: active.isNew)
    comments.activate(active)
    active.requestCreationFocus()
    openRequestedComments()
    // A completed restoration must not reopen detail after returning to Library.
    if library.state.selectedID != nil, active.file.revealsDetail {
      compactColumn = .detail
    }
    #if DEBUG
    presentFixtureSheet()
    #endif
  }

  /// Opens the comments a library row asked for, once its file is the active one.
  private func openRequestedComments() {
    guard let active, comments.requestedRowID == active.file.rowID,
      comments.sessionID == active.editor.id
    else { return }
    comments.requestedRowID = nil
    comments.open(for: active)
  }

  /// The account whose gists are up, or nil while one signs in, out or waits to replace it.
  private var settledAccountID: UUID? {
    library.isSigningIn || library.isSigningOut || library.pendingAccount != nil
      ? nil : library.account?.id
  }

  private var workspaceLifecycle: some View {
    workspaceNavigationLifecycle
    .onChange(of: scenePhase, initial: true) { library.isForeground = scenePhase == .active }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { publishOnBackground() }
      if phase == .active {
        Task { await library.publishDrafts() }
        Task { await library.refreshOnReturn() }
        library.updateCalendar()
        Task { await active?.inspectRemoteChanges() }
      }
    }
    .onChange(of: settledAccountID) {
      comments.reset()
      intelligence.target = nil
    }
    .onChange(of: library.account?.id) {
      columnVisibility = .all
      sheet = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      library.updateCalendar()
    }
  }

  private var workspaceSheets: some View {
    workspaceLifecycle
    .alert("GistPad", isPresented: $library.isShowingError) {
    } message: {
      Text(library.openError ?? "")
    }
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .settings: settingsSheet
      case .addToToday: AddToTodaySheet()
      case .tags(let target): tagEditor(target)
      case .name(let target): nameEditor(target)
      case .review(let target):
        ConflictReview(session: target.session, review: target.review)
      }
    }
  }

  /// The one sheet over the app. A link or another account replaces it.
  private enum Sheet: Identifiable {
    case settings, addToToday
    case tags(TagTarget)
    case name(RenameTarget)
    case review(ConflictTarget)

    var id: String {
      switch self {
      case .settings: "settings"
      case .addToToday: "addToToday"
      case .tags(let target): "tags/\(target.id)"
      case .name(let target): "name/\(target.id)"
      case .review(let target): "review/\(target.id)"
      }
    }
  }

  private var settingsSheet: some View {
    let account = library.account
    return SettingsSheet(
      account: account,
      savePreference: { key, value in
        guard let account else { throw AccountError.signedOut }
        _ = try await library.apply(.preferences([.setBoolean(key, value)]), accountID: account.id)
      },
      connect: {
        sheet = nil
        Task {
          await library.signIn()
          if library.account?.id == active?.draft.accountID,
            library.pendingAccount == nil, library.state.loadState == .ready
          {
            active?.didReconnect()
          }
        }
      },
      signOut: {
        guard let account else { throw AccountError.signedOut }
        _ = try await library.apply(.signOut, accountID: account.id)
      }
    ) {
      AccentColorRow(savedHex: account?.preferences.accentColor) { hex in
        guard let account else { throw AccountError.signedOut }
        _ = try await library.apply(.preferences([.setAccentColor(hex)]), accountID: account.id)
      }
    }
    .id(account?.id)
  }

  private var accountSwitchPresented: Binding<Bool> {
    Binding(
      get: { library.pendingAccount != nil },
      set: { presented in
        if !presented, library.pendingAccount != nil { library.keepCurrentAccount() }
      })
  }

  @ViewBuilder
  private var accountSwitchSheet: some View {
    if let account = library.account, let pending = library.pendingAccount {
      AccountSwitchSheet(
        current: account.login, replacement: pending.login,
        switchAccount: { try await library.switchAccount() },
        keepCurrent: { library.keepCurrentAccount() })
    }
  }

  var libraryActions: LibraryActions {
    var actions = LibraryActions(
      refresh: { await library.refresh() },
      create: { createGist() },
      today: { openToday() })
    actions.select = { selectRow($0) }
    actions.openComments = { rowID in
      comments.requestedRowID = rowID
      selectRow(rowID)
      openRequestedComments()
    }
    actions.account = { sheet = .settings }
    let reconnect: @MainActor () -> Void = {
      Task {
        await library.signIn()
        if library.account?.id == active?.draft.accountID,
          library.pendingAccount == nil, library.state.loadState == .ready
        {
          active?.didReconnect()
        }
      }
    }
    actions.reconnect = reconnect
    actions.recoverStatus = {
      switch (library.state.loadState, library.remoteRefreshProblem?.recovery) {
      case (.reconnectRequired, _), (_, .reconnect?):
        reconnect()
      default:
        Task { await library.refresh() }
      }
    }
    actions.togglePin = { rowID in
      guard let account = library.account, let id = library.gistID(forRow: rowID) else {
        library.openError = String(localized: "Save this local draft to GitHub before pinning it.")
        return
      }
      library.run(
        .preferences([.setPinned(gistID: id, pinned: !account.preferences.pinnedGists.contains(id))]),
        accountID: account.id)
    }
    actions.toggleArchive = { rowID in
      guard let account = library.account, let id = library.gistID(forRow: rowID),
        let gist = library.cachedLibrary?.gists.first(where: { $0.id == id })
      else {
        library.openError = String(
          localized: "A recovery or unpublished draft cannot be archived on GitHub.")
        return
      }
      setArchived(!gist.isArchived, gistID: id, accountID: account.id)
    }
    actions.delete = { rowID in
      guard let accountID = library.account?.id, let change = library.deletion(forRow: rowID)
      else { return }
      library.run(change, accountID: accountID)
    }
    return actions
  }

  private func fileScreen(
    _ session: FileSession, availableWidth: CGFloat
  ) -> some View {
    let identifier = onScreenNote(for: session).map {
      EntityIdentifier(for: GistEntity.self, identifier: $0.url.absoluteString)
    }
    return gistScreen(session, availableWidth: availableWidth)
      .imagePicker(images)
      .userActivity("dev.gistpad.GistPad.note", isActive: identifier != nil) { activity in
        activity.title = session.details.title
        activity.isEligibleForSearch = false
        activity.isEligibleForHandoff = false
        activity.appEntityIdentifier = identifier
      }
      .onChange(of: identifier, initial: true) { _, value in
        session.editor.textView.appEntityIdentifier = value
        PlatformBridge.shared?.setVisibleNote(value?.identifier, session: session)
      }
      .onDisappear {
        session.editor.textView.appEntityIdentifier = nil
        PlatformBridge.shared?.setVisibleNote(nil, session: session)
      }
  }

  private func onScreenNote(for session: FileSession) -> GistPadLink? {
    guard scenePhase == .active,
      horizontalSizeClass != .compact || compactColumn == .detail,
      library.state.selectedID != nil, sheet == nil,
      library.account?.id == session.draft.accountID, library.pendingAccount == nil,
      !session.file.isRecovery
    else { return nil }
    if let gist = session.file.gist {
      return .gist(
        id: gist.id,
        filename: session.file.filename == gist.defaultMarkdownFilename
          ? nil : session.file.filename)
    }
    guard session.draft.gistID == nil else { return nil }
    return .unpublishedGist(accountID: session.draft.accountID, draftID: session.draft.id)
  }

  private func gistScreen(
    _ session: FileSession, availableWidth: CGFloat
  ) -> some View {
    let mode = Binding(
      get: {
        if comments.isPresented, comments.matches(session.file) {
          return comments.fileMode
        }
        return layout.presentedMode(
          availableWidth: availableWidth, sessionMode: session.mode,
          isEditing: session.editor.isEditing,
          canEdit: session.details.access.canEdit)
      },
      set: {
        if comments.isPresented, comments.matches(session.file) {
          comments.fileMode = $0
        } else {
          layout.select($0)
          if $0 != .split { session.mode = $0 }
        }
        if $0 == .edit {
          session.editor.requestFocusAtContentStart()
        } else if $0 == .preview {
          session.editor.textView.resignFirstResponder()
        }
      })
    var details = session.details
    if comments.matches(session.file) {
      details.commentCount = comments.conversation?.comments?.count ?? details.commentCount
    }
    return GistScreen(
      gist: details, mode: mode,
      saveState: session.saveState, actions: gistActions(session),
      allowsSplit: !comments.isPresented && LayoutPreferences.allowsSplit(availableWidth: availableWidth),
      areCommentsPresented: comments.isPresented && comments.matches(session.file)
    ) {
      EditorView(
        editor: session.editor, title: details.title,
        insertImage: { comments.performAfterClosing { images.chooseImage(for: session) } },
        canInsertImage: images.canChooseImage(for: session),
        intelligence: { comments.performAfterClosing { presentIntelligence(session) } },
        comments: commentConfiguration(session),
        onOpenCommentThreads: commentOpener(session, origin: .edit),
        onLinkedCommentIDsChange: { ids in
          guard comments.sessionID == session.editor.id else { return }
          comments.sourceLinkedIDs = ids
        },
        onAddComment: commentComposer(session, origin: .edit))
    } preview: {
      preview(session)
    }
    .toolbar {
      if session.remoteInspectionStatus != .idle {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
          GitHubStatusControl(
            state: session.remoteInspectionStatus
          ) {
            Task {
              if session.remoteInspectionProblem?.recovery == .reconnect {
                await library.signIn()
                guard library.account?.id == session.draft.accountID,
                  library.pendingAccount == nil
                else { return }
                session.didReconnect()
              }
              await session.inspectRemoteChanges()
            }
          }
          .id(session.editor.id)
        }
        .sharedBackgroundVisibility(.hidden)
      }
    }
    .task(id: session.editor.id) { await session.inspectRemoteChanges() }
    .task(id: CommentReadInput(
      session: session.editor.id, gistID: session.file.gist?.id,
      knownTotal: session.file.gist?.commentCount,
      isReady: library.account?.id == session.draft.accountID
        && library.pendingAccount == nil && !library.isSigningIn && !library.isSigningOut,
      allowsComments: CommentsPresentation.supports(session.file),
      showsInline: library.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true)
    ) {
      guard library.account?.id == session.draft.accountID, library.pendingAccount == nil,
        !library.isSigningIn, !library.isSigningOut else { return }
      comments.activate(session)
      await comments.prepareAnnotations(
        for: session,
        showsInline: library.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true)
    }
    .onChange(of: LayoutPreferences.allowsSplit(availableWidth: availableWidth)) { _, allows in
      if !allows, layout.preferredMode == .split, session.editor.isEditing {
        session.mode = .edit
      }
    }
  }

  private func preview(_ session: FileSession) -> some View {
    let identifier = onScreenNote(for: session).map {
      EntityIdentifier(for: GistEntity.self, identifier: $0.url.absoluteString)
    }
    return FilePreview(
      editor: session.editor, allowsMutations: session.details.access.canEdit,
      comments: commentConfiguration(session),
      onOpenCommentThreads: commentOpener(session, origin: .preview),
      onLinkedCommentIDsChange: { ids in
        guard comments.sessionID == session.editor.id else { return }
        comments.previewLinkedIDs = ids
      },
      onAddComment: commentComposer(session, origin: .preview),
      openWikilink: { target in
        if let gist = library.state.gists.first(where: {
          $0.title.localizedStandardCompare(target) == .orderedSame
        }) {
          open(gistID: gist.id)
        } else {
          library.openError = String(localized: "No gist has that title.")
        }
      })
      .id(session.editor.id)
      .appEntityIdentifier(identifier)
  }

  private func commentConfiguration(
    _ session: FileSession
  ) -> CommentHighlightConfiguration {
    guard CommentsPresentation.supports(session.file),
      comments.matches(session.file), let conversation = comments.conversation
    else { return .init() }
    return .init(
      quotes: conversation.threads.compactMap(\.quotedPassage),
      selectedCommentID: comments.selectedRootID,
      revealRevision: comments.revealRevision,
      showsInlineComments:
        library.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true)
  }

  private func commentOpener(
    _ session: FileSession, origin: FileMode
  ) -> (@MainActor ([Int64]) -> Void)? {
    guard CommentsPresentation.supports(session.file) else { return nil }
    return { ids in
      guard comments.sessionID == session.editor.id else { return }
      if ids.count == 1, let id = ids.first {
        comments.open(for: session, origin: origin, rootID: id)
      } else if !ids.isEmpty {
        comments.fileMode = origin
        comments.overlappingIDs = ids
      } else {
        Logger(subsystem: "dev.gistpad.GistPad", category: "Comments")
          .error("A comment activation arrived without a thread identifier.")
      }
    }
  }

  private func commentComposer(
    _ session: FileSession, origin: FileMode
  ) -> (@MainActor (String) -> Void)? {
    guard CommentsPresentation.supports(session.file) else { return nil }
    return { selection in
      guard comments.sessionID == session.editor.id else { return }
      comments.open(for: session, origin: origin, quote: selection)
    }
  }

  private func afterCommentsClose(_ action: (() -> Void)?) -> (() -> Void)? {
    action.map(afterCommentsClose)
  }

  private func afterCommentsClose(_ action: @escaping () -> Void) -> () -> Void {
    { comments.performAfterClosing(action) }
  }

  private struct CommentReadInput: Hashable {
    let session: UUID
    let gistID: String?
    let knownTotal: Int?
    let isReady: Bool
    let allowsComments: Bool
    let showsInline: Bool
  }

  /// What Delete on a file's screen removes, the same as its Library row: a copy that's only on
  /// this iPhone, one day of the daily notes gist, or the whole gist.
  private func deletion(_ session: FileSession) -> Change? {
    if session.file.isRecovery || session.draft.gistID == nil {
      return .discardLocalCopy(session.draft)
    }
    guard let gist = session.file.gist, session.details.access.canEdit else { return nil }
    if gist.isDailyNote {
      return .deleteFile(gistID: gist.id, filename: session.file.filename)
    }
    return .delete(gistID: gist.id)
  }

  private func gistActions(_ session: FileSession) -> GistActions {
    var actions = GistActions()
    if CommentsPresentation.supports(session.file) {
      actions.comments = {
        if comments.isPresented {
          comments.hide()
        } else {
          comments.open(for: session)
        }
      }
    }
    actions.save = { publish(session) }
    actions.reviewChanges = {
      do {
        sheet = .review(.init(session: session, review: try session.reviewContext()))
      } catch { library.openError = error.localizedDescription }
    }
    actions.reconnect = {
      Task {
        await library.signIn()
        if library.account?.id == session.draft.accountID,
          library.pendingAccount == nil, library.state.loadState == .ready
        {
          session.didReconnect()
        }
      }
    }
    if let gistID = session.file.gist?.id {
      actions.selectFile = { open(gistID: gistID, filename: $0) }
      actions.tags = {
        sheet = .tags(
          TagTarget(
            accountID: session.draft.accountID, gistID: gistID,
            selected: Set(session.details.tags.map(\.id)),
            canEdit: library.account?.id == session.draft.accountID
              && library.pendingAccount == nil && !session.file.isRecovery))
      }
      if !session.file.isRecovery {
        actions.togglePin = {
          library.run(
            .preferences([.setPinned(gistID: gistID, pinned: !session.details.isPinned)]),
            accountID: session.draft.accountID)
        }
        actions.toggleStar = {
          library.run(
            .star(gistID: gistID, starred: !session.details.isStarred),
            accountID: session.draft.accountID)
        }
        if session.details.access.canEdit {
          actions.toggleArchive = {
            setArchived(
              !session.details.isArchived, gistID: gistID,
              accountID: session.draft.accountID)
          }
          actions.addFile = { rename(.addFile, session: session) }
          actions.renameFile = { rename(.filename, session: session) }
        }
      }
    }
    if session.details.access.canEdit, !session.file.isRecovery {
      actions.rename = { rename(.title, session: session) }
    }
    if deletion(session) != nil {
      actions.delete = {
        // Read at confirmation, so a file that published meanwhile deletes from GitHub.
        guard let change = deletion(session) else { return }
        library.run(change, accountID: session.draft.accountID)
      }
    }
    actions.find = {
      session.mode = .edit
      session.editor.find(replacing: true)
    }
    actions.intelligence = { presentIntelligence(session) }
    if !session.file.isRecovery, let gist = session.file.gist {
      actions.openInGitHub = {
        do { openURL(try GistLinks(gist: gist).githubURL) } catch {
          library.openError = error.localizedDescription
        }
      }
    }
    actions.intelligence = afterCommentsClose(actions.intelligence)
    actions.tags = afterCommentsClose(actions.tags)
    actions.rename = afterCommentsClose(actions.rename)
    actions.renameFile = afterCommentsClose(actions.renameFile)
    actions.addFile = afterCommentsClose(actions.addFile)
    actions.find = afterCommentsClose(actions.find)
    actions.reviewChanges = afterCommentsClose(actions.reviewChanges)
    actions.delete = afterCommentsClose(actions.delete)
    return actions
  }

  private func open(gistID: String, filename: String? = nil) {
    Task { await library.open(.gist(id: gistID, filename: filename)) }
  }

  private func selectRow(_ id: String) {
    library.select(rowID: id)
    compactColumn = .detail
  }

  private func publish(_ session: FileSession) {
    guard session.canMutate else {
      library.openError = String(
        localized: "Finish composition or Writing Tools before saving to GitHub.")
      return
    }
    Task { await session.publish() }
  }

  private func presentIntelligence(_ session: FileSession) {
    guard session.editor.isSettled else {
      library.openError = String(
        localized: "Finish composition or Writing Tools before opening Intelligence.")
      return
    }
    intelligence.present(
      editor: session.editor, title: session.details.title,
      revealSource: { range in
        guard session.details.access.canEdit else {
          library.openError = String(
            localized: "This gist is read-only, so the reference can't open in the editor.")
          return
        }
        let generation = session.editor.generation
        guard Range(range, in: session.editor.text) != nil else {
          library.openError = String(localized: "This reference no longer matches the file.")
          return
        }
        layout.select(.edit)
        session.mode = .edit
        Task { @MainActor in
          await Task.yield()
          guard session.editor.generation == generation else {
            library.openError = String(localized: "This reference no longer matches the file.")
            return
          }
          let view = session.editor.textView
          view.selectedRange = range
          view.layoutIfNeeded()
          view.scrollRangeToVisible(range)
          if !view.becomeFirstResponder() {
            session.editor.inputError = String(localized: "Tap the file to resume writing.")
          }
        }
      })
  }

  private func rename(_ kind: RenameTarget.Kind, session: FileSession) {
    sheet = .name(
      RenameTarget(draft: session.draft, title: session.details.title, kind: kind))
  }

  private func nameEditor(_ target: RenameTarget) -> some View {
    RenameSheet(
      title: target.kind == .title
        ? String(localized: "Rename Gist")
        : (target.kind == .filename
          ? String(localized: "Rename File") : String(localized: "Add File")),
      fieldTitle: target.kind == .title ? String(localized: "Name") : String(localized: "Filename"),
      initialValue: target.kind == .title
        ? target.title : (target.kind == .filename ? target.draft.filename : ""),
      isFilename: target.kind != .title
    ) { value in
      let action: Change
      switch target.kind {
      case .title:
        if let gistID = target.draft.gistID {
          action = .rename(gistID: gistID, title: value)
        } else {
          action = .renameLocal(target.draft, title: value)
        }
      case .filename:
        guard let gistID = target.draft.gistID else { throw GistLinks.Error.notPublished }
        action = .renameFile(gistID: gistID, filename: target.draft.filename, newFilename: value)
      case .addFile:
        guard let gistID = target.draft.gistID else { throw GistLinks.Error.notPublished }
        action = .addFile(gistID: gistID, filename: value)
      }
      _ = try await library.apply(action, accountID: target.draft.accountID)
    }
  }

  private func tagEditor(_ target: TagTarget) -> some View {
    let save: (@MainActor @Sendable ([TagEdit]) async throws -> Void)?
    if target.canEdit {
      save = { edits in
        let operations = edits.map { edit -> Preferences.Change in
          switch edit {
          case .setMembership(let id, let included):
            .setTag(gistID: target.gistID, tagID: id, included: included)
          case .upsert(let tag): .upsertTag(id: tag.id, name: tag.name, color: tag.colorHex)
          case .delete(let id): .deleteTag(id: id)
          }
        }
        _ = try await library.apply(.preferences(operations), accountID: target.accountID)
      }
    } else {
      save = nil
    }
    return TagEditor(
      tags: library.state.tags, selectedTagIDs: target.selected, save: save)
  }

  /// Archiving is absolute, so its undo is the opposite archive, registered with the scene so
  /// shake to undo and the undo gesture reverse it.
  private func setArchived(_ archived: Bool, gistID: String, accountID: UUID) {
    library.run(.archive(gistID: gistID, archived: archived), accountID: accountID)
    undoManager?.registerUndo(withTarget: library) { _ in
      setArchived(!archived, gistID: gistID, accountID: accountID)
    }
    undoManager?.setActionName(
      archived ? String(localized: "Archive") : String(localized: "Unarchive"))
  }

  private func createGist() {
    Task { await library.open(.new) }
  }

  private func openToday() {
    compactColumn = .detail
    let target = DailyNote.Day()
    Task { await library.open(.today(target)) }
  }

  /// The pending link, once the account it opens in has settled.
  private var linkToOpen: GistPadLink? {
    guard !library.isStarting, !library.isSigningIn, library.pendingAccount == nil else {
      return nil
    }
    return pending.link
  }

  #if DEBUG
  /// Presents a fixture launch's `--sheet` once its file is open and activated. The link can
  /// clear before the file it opened activates, and Comments only opens for the activated file.
  private func presentFixtureSheet() {
    guard let fixtureSheet = FixtureLaunch.pendingSheet, pending.link == nil, let active,
      comments.sessionID == active.editor.id
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
    guard let link = linkToOpen, let account = library.account else { return }
    sheet = nil
    intelligence.target = nil
    library.openError = nil
    switch link {
    case .today:
      // Like the Today button, a folded phone shows Today while it's staged.
      compactColumn = .detail
      await library.open(.today())
    case .addToToday:
      sheet = .addToToday
    case .newGist:
      await library.open(.new)
    case .gist(let id, let filename):
      await library.open(.gist(id: id, filename: filename))
    case .unpublishedGist(let accountID, let draftID):
      guard accountID == account.id else {
        library.openError = "This draft belongs to another GitHub account. Switch accounts to open it."
        pending.link = nil
        return
      }
      await library.open(.draft(id: draftID))
    }
    guard !Task.isCancelled, pending.link == link else { return }
    if library.visibleFile != nil || library.opening?.failure != nil {
      compactColumn = .detail
    }
    pending.link = nil
  }

  private func publishOnBackground() {
    let lease = BackgroundLease()
    let sessions = Array(library.sessions.values)
    let publishing = Task {
      await FileSession.publishOnBackground(sessions, shouldContinue: { lease.isActive })
      lease.end()
    }
    lease.onExpiration = { publishing.cancel() }
  }
}

@MainActor
final class BackgroundLease {
  private var identifier = UIBackgroundTaskIdentifier.invalid
  private var expired = false
  var onExpiration: (() -> Void)?

  var isActive: Bool { !expired && identifier != .invalid }

  init() {
    identifier = UIApplication.shared.beginBackgroundTask(
      withName: "Publish changes"
    ) {
      [weak self] in
      Task { @MainActor in
        Logger(subsystem: "dev.gistpad.GistPad", category: "Library")
          .info("Background publish time expired. Local drafts are retained.")
        self?.expire()
      }
    }
  }

  func expire() {
    guard !expired else { return }
    expired = true
    onExpiration?()
    end()
  }

  func end() {
    onExpiration = nil
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
