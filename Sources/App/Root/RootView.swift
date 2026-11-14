import AppIntents
import Comments
import Editor
import Screens
import Model
import Observation
import OSLog
import Platform
import SwiftUI
import Store

struct RootView: View {
  @Bindable var model: GistPadModel
  private let pending: PendingLink
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var sheet: Sheet?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var layout = LayoutPreferences()
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
    _images = State(initialValue: ImageUpload(upload: model.uploadImage))
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

  var body: some View {
    workspaceSheets
      .sheet(isPresented: accountSwitchPresented) {
        accountSwitchSheet
      }
      .intelligenceSheet(intelligence)
  }

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
  }

  /// Signed out once launch knows there's no account, so the list doesn't flash the invitation.
  private var isSignedOut: Bool { model.account == nil && model.phase != .loading }

  private var isLoadingLibrary: Bool { model.phase == .loading || model.phase == .refreshing }

  private var library: some View {
    LibraryView(
      state: model.state, actions: libraryActions, isSidebar: horizontalSizeClass == .regular,
      isSignedOut: isSignedOut, isLoading: isLoadingLibrary, status: model.remoteRefreshStatus,
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
        GeometryReader { geometry in
          if let opening = model.opening, let failure = opening.failure {
            OpenFailedView(gist: openingDetails(title: opening.title), message: failure) {
              Task { await model.open(opening.request) }
            }
          } else if let active {
            fileScreen(active, availableWidth: geometry.size.width)
          } else if let file = model.visibleFile {
            OpeningFileView(gist: model.details(for: file), file: file)
              .id(file.id)
          } else if let title = model.openingTitle {
            OpeningFileView(gist: openingDetails(title: title))
              .id(model.opening?.rowID ?? model.state.selectedID)
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

  private var workspaceNavigationLifecycle: some View {
    navigation
    .task {
      await model.start()
      await model.returnToApp()
    }
    .task(id: linkToOpen) { await openPendingLink() }
    #if DEBUG
    .onChange(of: pending.link) { presentFixtureSheet() }
    #endif
    .background {
      // Keyed by activation instead of onChange, because SwiftUI drops onChange actions past a
      // few per frame. A launch link can restore today, open, and present a new note in one.
      Color.clear.onAppear(perform: didActivate).id(active?.activationID)
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

  /// Prepares a file as it comes into the detail column.
  private func didActivate() {
    guard let active else { return }
    active.mode = layout.initialMode(isUnpublished: active.file.isNew)
    comments.activate(active)
    active.requestCreationFocus()
    openRequestedComments()
    // A completed restoration must not reopen detail after returning to Library.
    if model.state.selectedID != nil, active.revealsDetail {
      compactColumn = .detail
    }
    #if DEBUG
    presentFixtureSheet()
    #endif
  }

  /// Opens the comments a library row asked for, once its file is the active one.
  private func openRequestedComments() {
    guard let active, comments.requestedRowID == model.loadedRowID,
      comments.editorID == active.editor.id
    else { return }
    comments.requestedRowID = nil
    comments.open(for: active)
  }

  /// The account whose gists are up, or nil while one signs in, out or waits to replace it.
  private var settledAccountID: UUID? {
    model.phase.isChangingAccount ? nil : model.account?.id
  }

  private var workspaceLifecycle: some View {
    workspaceNavigationLifecycle
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
  }

  private var workspaceSheets: some View {
    workspaceLifecycle
    .alert("GistPad", isPresented: $model.isShowingError) {
    } message: {
      Text(model.alertMessage ?? "")
    }
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .settings: settingsSheet
      case .addToToday: AddToTodaySheet()
      case .tags(let target): tagEditor(target)
      case .rename(let target): renameSheet(target)
      case .review(let target):
        ConflictReview(fileEditor: target.fileEditor, review: target.review)
      }
    }
  }

  /// The one sheet over the app. A link or another account replaces it.
  private enum Sheet: Identifiable {
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

  private var accountSwitchPresented: Binding<Bool> {
    Binding(
      get: { model.phase.switchingTo != nil },
      set: { presented in
        if !presented, model.phase.switchingTo != nil { model.keepCurrentAccount() }
      })
  }

  @ViewBuilder
  private var accountSwitchSheet: some View {
    if let account = model.account, let pending = model.phase.switchingTo {
      AccountSwitchSheet(
        current: account.github.login, replacement: pending.github.login,
        switchAccount: { try await model.switchAccount() },
        keepCurrent: { model.keepCurrentAccount() })
    }
  }

  var libraryActions: LibraryActions {
    var actions = LibraryActions(
      refresh: { await model.refresh() },
      create: { createGist() },
      today: { openToday() })
    actions.select = { selectRow($0) }
    actions.openComments = { rowID in
      comments.requestedRowID = rowID
      selectRow(rowID)
      openRequestedComments()
    }
    actions.account = { sheet = .settings }
    actions.reconnect = { Task { await model.reconnect() } }
    actions.recoverStatus = {
      Task {
        if model.problem == .reconnect {
          await model.reconnect()
        } else {
          await model.refresh()
        }
      }
    }
    actions.togglePin = { rowID in
      guard let account = model.account, let id = model.gistID(forRow: rowID) else {
        model.alertMessage = String(localized: "Save this local draft to GitHub before pinning it.")
        return
      }
      let pinned = !account.preferences.pinnedGists.contains(id)
      model.run { try await model.updatePreferences([.setPinned(gistID: id, pinned: pinned)]) }
    }
    actions.toggleArchive = { rowID in
      guard let id = model.gistID(forRow: rowID),
        let gist = model.gistCache?.gists.first(where: { $0.id == id })
      else {
        model.alertMessage = String(
          localized: "A recovery or unpublished draft cannot be archived on GitHub.")
        return
      }
      setArchived(!gist.isArchived, gistID: id)
    }
    actions.delete = { rowID in
      guard let deletion = model.deletion(forRow: rowID) else { return }
      model.run { try await model.delete(deletion) }
    }
    return actions
  }

  private func fileScreen(
    _ fileEditor: GistFileEditor, availableWidth: CGFloat
  ) -> some View {
    let identifier = entityIdentifier(for: fileEditor)
    return gistScreen(fileEditor, availableWidth: availableWidth)
      .imagePicker(images)
      .userActivity("dev.gistpad.GistPad.note", isActive: identifier != nil) { activity in
        activity.title = fileEditor.details.title
        activity.isEligibleForSearch = false
        activity.isEligibleForHandoff = false
        activity.appEntityIdentifier = identifier
      }
      .onChange(of: identifier, initial: true) { _, value in
        fileEditor.editor.entityIdentifier = value
        PlatformBridge.shared?.setVisibleNote(value?.identifier, fileEditor: fileEditor)
      }
      .onDisappear {
        fileEditor.editor.entityIdentifier = nil
        PlatformBridge.shared?.setVisibleNote(nil, fileEditor: fileEditor)
      }
  }

  private func entityIdentifier(for fileEditor: GistFileEditor) -> EntityIdentifier? {
    onScreenNote(for: fileEditor).map {
      EntityIdentifier(for: GistEntity.self, identifier: $0.url.absoluteString)
    }
  }

  private func onScreenNote(for fileEditor: GistFileEditor) -> GistPadLink? {
    guard scenePhase == .active,
      horizontalSizeClass != .compact || compactColumn == .detail,
      model.state.selectedID != nil, sheet == nil,
      model.account?.id == fileEditor.file.accountID, model.phase.switchingTo == nil,
      !fileEditor.file.isDeletedOnGitHub
    else { return nil }
    if let gist = fileEditor.file.gist {
      return .gist(
        id: gist.id,
        filename: fileEditor.file.filename == gist.defaultMarkdownFilename
          ? nil : fileEditor.file.filename)
    }
    guard fileEditor.file.gistID == nil else { return nil }
    return .unpublishedGist(accountID: fileEditor.file.accountID, draftID: fileEditor.file.id)
  }

  private func gistScreen(
    _ fileEditor: GistFileEditor, availableWidth: CGFloat
  ) -> some View {
    let mode = Binding(
      get: {
        if comments.isPresented, comments.matches(fileEditor.file) {
          return comments.fileMode
        }
        return layout.presentedMode(
          availableWidth: availableWidth, sessionMode: fileEditor.mode,
          isEditing: fileEditor.editor.isEditing,
          canEdit: fileEditor.details.isOwned)
      },
      set: {
        if comments.isPresented, comments.matches(fileEditor.file) {
          comments.fileMode = $0
        } else {
          layout.select($0)
          if $0 != .split { fileEditor.mode = $0 }
        }
        if $0 == .edit {
          fileEditor.editor.requestFocusAtContentStart()
        } else if $0 == .preview {
          fileEditor.editor.endEditing()
        }
      })
    var details = fileEditor.details
    if comments.matches(fileEditor.file) {
      details.commentCount = comments.model?.comments?.count ?? details.commentCount
    }
    return GistScreen(
      gist: details, mode: mode,
      status: fileEditor.status, actions: gistActions(fileEditor),
      allowsSplit: !comments.isPresented && LayoutPreferences.allowsSplit(availableWidth: availableWidth),
      areCommentsPresented: comments.isPresented && comments.matches(fileEditor.file)
    ) {
      let highlights = comments.highlights(for: fileEditor, origin: .edit)
      EditorView(
        editor: fileEditor.editor, title: details.title,
        insertImage: images.canChooseImage(for: fileEditor)
          ? { @MainActor in comments.performAfterClosing { images.chooseImage(for: fileEditor) } }
          : nil,
        intelligence: { comments.performAfterClosing { presentIntelligence(fileEditor) } },
        comments: highlights.configuration, commentActions: highlights.actions)
    } preview: {
      preview(fileEditor)
    }
    .toolbar {
      if fileEditor.remoteInspectionStatus != .idle {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
          GitHubStatusControl(
            state: fileEditor.remoteInspectionStatus
          ) {
            Task {
              if fileEditor.remoteInspectionProblem == .reconnect { await model.reconnect() }
              await fileEditor.inspectRemoteChanges()
            }
          }
          .id(fileEditor.editor.id)
        }
        .sharedBackgroundVisibility(.hidden)
      }
    }
    .task(id: fileEditor.editor.id) { await fileEditor.inspectRemoteChanges() }
    .task(id: comments.tracking(fileEditor)) { await comments.track(fileEditor) }
    .onChange(of: LayoutPreferences.allowsSplit(availableWidth: availableWidth)) { _, allows in
      if !allows, layout.preferredMode == .split, fileEditor.editor.isEditing {
        fileEditor.mode = .edit
      }
    }
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
          open(gistID: gist.id)
        } else {
          model.alertMessage = String(localized: "No gist has that title.")
        }
      })
      .id(fileEditor.editor.id)
      .appEntityIdentifier(entityIdentifier(for: fileEditor))
  }

  private func afterCommentsClose(_ action: (() -> Void)?) -> (() -> Void)? {
    action.map(afterCommentsClose)
  }

  private func afterCommentsClose(_ action: @escaping () -> Void) -> () -> Void {
    { comments.performAfterClosing(action) }
  }

  private func gistActions(_ fileEditor: GistFileEditor) -> GistActions {
    var actions = GistActions()
    if CommentsPresentation.supports(fileEditor.file) {
      actions.comments = {
        if comments.isPresented {
          comments.hide()
        } else {
          comments.open(for: fileEditor)
        }
      }
    }
    actions.reviewChanges = {
      guard let review = fileEditor.file.draft, review.conflict != nil else { return }
      sheet = .review(.init(fileEditor: fileEditor, review: review))
    }
    actions.reconnect = { Task { await model.reconnect() } }
    if let gistID = fileEditor.file.gist?.id {
      actions.selectFile = { open(gistID: gistID, filename: $0) }
      actions.tags = {
        sheet = .tags(
          TagTarget(
            accountID: fileEditor.file.accountID, gistID: gistID,
            selected: Set(model.account?.preferences.gistTags[gistID] ?? []),
            canEdit: model.account?.id == fileEditor.file.accountID
              && model.phase.switchingTo == nil && !fileEditor.file.isDeletedOnGitHub))
      }
      if !fileEditor.file.isDeletedOnGitHub {
        actions.togglePin = {
          let pinned = !fileEditor.details.isPinned
          model.run {
            try await model.updatePreferences([.setPinned(gistID: gistID, pinned: pinned)])
          }
        }
        actions.toggleStar = {
          let starred = !fileEditor.details.isStarred
          model.run { try await model.setStarred(starred, gistID: gistID) }
        }
        if fileEditor.details.isOwned {
          actions.toggleArchive = { setArchived(!fileEditor.details.isArchived, gistID: gistID) }
          actions.addFile = { rename(.addFile, fileEditor: fileEditor) }
          actions.renameFile = { rename(.filename, fileEditor: fileEditor) }
        }
      }
    }
    if fileEditor.details.isOwned, !fileEditor.file.isDeletedOnGitHub {
      actions.rename = { rename(.title, fileEditor: fileEditor) }
    }
    if fileEditor.deletion != nil {
      actions.delete = {
        // Read at confirmation, so a file that published meanwhile deletes from GitHub.
        guard let deletion = fileEditor.deletion else { return }
        model.run { try await model.delete(deletion) }
      }
    }
    actions.find = {
      fileEditor.mode = .edit
      fileEditor.editor.find(replacing: true)
    }
    actions.intelligence = { presentIntelligence(fileEditor) }
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
    Task { await model.open(.gist(id: gistID, filename: filename)) }
  }

  /// What a note on its way will show once it's open, from its row and the gist this iPhone
  /// has, so the bar doesn't change when it arrives.
  private func openingDetails(title: String) -> GistDetails {
    let opening = model.opening
    let row = model.state.gists.first { $0.id == (opening?.rowID ?? model.state.selectedID) }
    var gistID = row.map { $0.gistID ?? $0.id }
    var isDailyNote = row?.isDailyNote ?? false
    switch opening?.request {
    case .gist(let id, _, _): gistID = id
    case .today: isDailyNote = true
    default: break
    }
    let gist = model.gistCache?.gists.first { $0.id == gistID }
    isDailyNote = isDailyNote || gist?.isDailyNote == true
    let filename =
      opening?.filename ?? row?.filename
      ?? (isDailyNote ? DailyNote.filename() : gist?.defaultMarkdownFilename) ?? ""
    let filenames = Set((gist?.markdownFilenames ?? []) + [filename]).sorted()
    return GistDetails(
      title: title, filenames: filenames, filename: filename, isDailyNote: isDailyNote)
  }

  private func selectRow(_ id: String) {
    model.open(rowID: id)
    compactColumn = .detail
  }

  private func presentIntelligence(_ fileEditor: GistFileEditor) {
    intelligence.present(fileEditor, model: model) { layout.select(.edit) }
  }

  private func rename(_ kind: RenameTarget.Kind, fileEditor: GistFileEditor) {
    sheet = .rename(
      RenameTarget(draft: fileEditor.file.nextDraft, title: fileEditor.details.title, kind: kind))
  }

  private func renameSheet(_ target: RenameTarget) -> some View {
    RenameSheet(target) { value in
      let draft = target.draft
      switch target.kind {
      case .title:
        try await model.rename(draft, to: value)
      case .filename:
        try await model.renameFile(draft, to: value)
      case .addFile:
        guard let gistID = draft.gistID else { throw ChangeError.publicationInProgress }
        try await model.addFile(named: value, to: gistID)
      }
    }
  }

  private func tagEditor(_ target: TagTarget) -> some View {
    TagEditor(
      gistID: target.gistID, tags: model.state.tags, selectedTagIDs: target.selected,
      save: target.canEdit ? model.updatePreferences : nil)
  }

  /// Archiving is absolute, so its undo is the opposite archive, registered with the scene so
  /// shake to undo and the undo gesture reverse it.
  private func setArchived(_ archived: Bool, gistID: String) {
    model.run { try await model.setArchived(archived, gistID: gistID) }
    undoManager?.registerUndo(withTarget: model) { _ in
      setArchived(!archived, gistID: gistID)
    }
    undoManager?.setActionName(
      archived ? String(localized: "Archive") : String(localized: "Unarchive"))
  }

  private func createGist() {
    Task { await model.open(.new) }
  }

  private func openToday() {
    compactColumn = .detail
    let target = DailyNote.Day()
    Task { await model.open(.today(target)) }
  }

  /// The pending link, once the account it opens in has settled.
  private var linkToOpen: GistPadLink? {
    guard model.phase != .loading, model.phase != .signingIn, model.phase.switchingTo == nil else {
      return nil
    }
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
    model.alertMessage = nil
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
        model.alertMessage = "This draft belongs to another GitHub account. Switch accounts to open it."
        pending.link = nil
        return
      }
      await model.open(.draft(id: draftID))
    }
    guard !Task.isCancelled, pending.link == link else { return }
    if model.visibleFile != nil || model.opening?.failure != nil {
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
