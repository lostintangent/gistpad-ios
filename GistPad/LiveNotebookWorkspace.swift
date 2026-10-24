import GistPadEditor
import GistPadInterface
import GistPadPlatform
import GistPadSync
import OSLog
import Observation
import SwiftUI

struct LiveNotebookWorkspace: View {
  @Bindable var notebook: NotebookModel
  private let routes: NotebookRouteInbox
  @State private var sessions: [String: NotebookSessionController] = [:]
  @State private var photoControllers: [String: NotebookPhotoController] = [:]
  @State private var activity = NotebookWorkspaceActivity()
  @State private var sourceDiagnostics = NotebookSourceDiagnostics()
  @State private var openRequest = UUID()
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var actionMessage: String?
  @State private var shareURL: URL?
  @State private var showingShare = false
  @State private var sharingTarget: NotebookSharingTarget?
  @State private var tagTarget: NotebookTagTarget?
  @State private var nameTarget: NotebookNameTarget?
  @State private var deletionTarget: NotebookDeletionTarget?
  @State private var libraryDeletionRowID: String?
  @State private var creationChoiceTarget: NotebookCreationChoiceTarget?
  @State private var reviewTarget: NotebookConflictTarget?
  @State private var isPerformingAction = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var layout = NotebookLayoutPreferences()
  @State private var archiveUndo: NotebookArchiveUndo?
  @State private var showingSettings = false
  @State private var showingAddToToday = false
  @State private var sharedPreviewGistID: String?
  @State private var intelligence = NotebookIntelligencePresentation()
  @State private var intelligenceAccountScope = UUID()
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isGitHubStatusVisible) private var isGitHubStatusVisible

  init(
    notebook: NotebookModel, layout: NotebookLayoutPreferences = NotebookLayoutPreferences(),
    routes: NotebookRouteInbox = .shared
  ) {
    self.notebook = notebook
    self.routes = routes
    _layout = State(initialValue: layout)
  }

  #if DEBUG
  func captureColumnVisibility(_ visibility: NavigationSplitViewVisibility) -> Self {
    var workspace = self
    workspace._columnVisibility = State(initialValue: visibility)
    return workspace
  }
  #endif

  private var active: NotebookSessionController? {
    activeID.flatMap { sessions[$0] }
  }

  private struct NotebookCreationChoiceTarget {
    let controller: NotebookSessionController
    let generation: UInt64
    let choice: NotebookCreationChoice
  }

  private var activeID: String? {
    get { activity.activeID }
    nonmutating set { activity.activeID = newValue }
  }

  var body: some View {
    workspaceSheets
      .sheet(isPresented: accountSwitchPresented) {
        accountSwitchSheet
          .personalAccent(savedHex: notebook.account?.preferences.accentColor)
      }
      .confirmationDialog(
        String(localized: "Delete “\(deletionTarget?.title ?? "")” from GitHub?"),
        isPresented: Binding(
          get: { deletionTarget != nil && libraryDeletionRowID == nil },
          set: { if !$0, libraryDeletionRowID == nil { deletionTarget = nil } }),
        titleVisibility: .visible
      ) {
        if let target = deletionTarget {
          Button("Delete from GitHub", role: .destructive) {
            run(.delete(gistID: target.id), accountID: target.accountID)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This deletes every file in the gist. Unsynced local drafts and recovery copies are kept on this iPhone."
        )
      }
      .confirmationDialog(
        creationChoiceTarget?.choice == .discard
          ? String(localized: "Discard this local copy?")
          : String(localized: "Publish as a new note?"),
        isPresented: Binding(
          get: { creationChoiceTarget != nil },
          set: { if !$0 { creationChoiceTarget = nil } }),
        titleVisibility: .visible
      ) {
        if let target = creationChoiceTarget {
          if target.choice == .discard {
            Button("Discard This Copy", role: .destructive) { resolveCreation(target) }
          } else {
            Button("Publish as New Note") { resolveCreation(target) }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        if creationChoiceTarget?.choice == .discard {
          Text("This removes this copy, its pending photos and local recovery history from this iPhone. It doesn't delete anything on GitHub. This cannot be undone.")
        } else {
          Text("GitHub may already have created the original note. This creates a separate note and may duplicate it. Check GitHub before continuing.")
        }
      }
      .notebookIntelligence(intelligence)
      .personalAccent(savedHex: notebook.account?.preferences.accentColor)
  }

  private var navigation: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn
    ) {
      LibraryView(
        model: notebook.library, actions: libraryActions,
        isTodaySelected: (horizontalSizeClass == .regular || compactColumn == .detail)
          && notebook.failedOpen == nil && notebook.presentedDocument == nil
          && notebook.openingTitle == nil,
        isSidebar: horizontalSizeClass == .regular)
    } detail: {
      NavigationStack {
        GeometryReader { geometry in
          if let failure = notebook.failedOpen {
            NotebookFailedOpeningView(failure: failure) {
              Task { await notebook.retryFailedOpen() }
            }
          } else if let document = notebook.presentedDocument {
            if let active, active.document.refersToSameFile(as: document) {
              note(active, availableWidth: geometry.size.width)
            } else {
              NotebookOpeningView(title: document.chrome.title, document: document)
                .id(document.id)
            }
          } else if let title = notebook.openingTitle {
            NotebookOpeningView(title: title)
              .id(notebook.openingDocument?.rowID ?? notebook.library.selectedNoteID)
          } else {
            TodayLanding(summary: notebook.library.today, start: { startToday() })
              .disabled(notebook.account == nil || notebook.isCreating)
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .librarySearch(model: notebook.library)
  }

  private var workspaceNavigationLifecycle: some View {
    navigation
    .task { await notebook.start() }
    .task(id: notebook.loadedDocument?.id) {
      if notebook.loadedDocument == nil { activeID = nil } else { await activateLoadedDocument() }
    }
    .task(id: searchInput) { await notebook.search() }
    .task(id: routeReadiness) { await receivePendingRoute() }
    .onChange(of: autosaveInput, initial: true) {
      for controller in sessions.values {
        controller.updateAutosave(isForeground: scenePhase == .active)
      }
    }
    .onChange(of: notebook.library.selectedNoteID) { _, selected in
      guard let selected, selected != notebook.loadedDocument?.rowID,
        selected != notebook.openingDocument?.rowID, selected != notebook.failedOpen?.rowID
      else { return }
      selectRow(selected)
    }
    .onChange(of: notebook.library.selectedNoteID) { previous, selected in
      guard previous != selected, let previous,
        let outgoing = sessions.values.first(where: { $0.document.rowID == previous })
      else { return }
      finishLeavingNote(outgoing)
    }
    .onChange(of: activeID) { previous, current in
      guard previous != current, let previous, let outgoing = sessions[previous] else { return }
      finishLeavingNote(outgoing)
    }
    .onChange(of: compactColumn) { previous, current in
      guard previous != current, current == .sidebar, let outgoing = active else { return }
      finishLeavingNote(outgoing)
    }
  }

  private var workspaceLifecycle: some View {
    workspaceNavigationLifecycle
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { finishBackgroundSaves() }
      if phase == .active {
        Task {
          await notebook.updateCalendar()
          await active?.inspectRemoteChanges()
        }
      }
    }
    .onChange(of: notebook.cachedLibrary?.cachedAt) {
      NotebookPlatformBootstrap.scheduleRefresh()
      Task { await active?.inspectRemoteChanges() }
    }
    .onChange(of: notebook.account, initial: true) {
      NotebookPlatformBootstrap.scheduleRefresh()
    }
    .onChange(of: notebook.pendingAccount?.id) {
      NotebookPlatformBootstrap.scheduleRefresh()
    }
    .onChange(of: notebook.localDrafts) {
      NotebookPlatformBootstrap.scheduleRefresh()
    }
    .onChange(of: notebook.account?.id) { _, accountID in
      archiveUndo = nil
      intelligenceAccountScope = UUID()
      intelligence.target = nil
      creationChoiceTarget = nil
      let inactivePhotos = photoControllers.values.filter { $0.accountID != accountID }
      if accountID == nil {
        sessions.removeAll()
        photoControllers.removeAll()
        activeID = nil
        showingSettings = false
      }
      Task { for photos in inactivePhotos { await photos.stop() } }
    }
    .onChange(of: notebook.isSigningIn) { _, signingIn in
      if signingIn {
        intelligenceAccountScope = UUID()
        intelligence.target = nil
        creationChoiceTarget = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      Task { await notebook.updateCalendar() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
      Task { await notebook.updateCalendar() }
    }
  }

  private var workspaceSheets: some View {
    workspaceLifecycle
    .alert(
      "GistPad",
      isPresented: Binding(
        get: { actionMessage != nil || notebook.documentError != nil },
        set: {
          if !$0 {
            actionMessage = nil
            notebook.documentError = nil
          }
        })
    ) {
      Button("OK") {
        actionMessage = nil
        notebook.documentError = nil
      }
    } message: {
      Text(actionMessage ?? notebook.documentError ?? "")
    }
    .sheet(isPresented: $showingShare) {
      if let shareURL {
        NotebookActivitySheet(item: .url(shareURL))
          .personalAccent(savedHex: notebook.account?.preferences.accentColor)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let undo = archiveUndo, notebook.account?.id == undo.accountID {
        HStack(spacing: 16) {
          Label(
            undo.wasArchived
              ? String(localized: "Note unarchived") : String(localized: "Note archived"),
            systemImage: "archivebox")
          Spacer()
          Button("Undo") {
            run(.undoArchive(undo), accountID: undo.accountID)
          }
          .disabled(isPerformingAction)
          Button("Dismiss", systemImage: "xmark") { archiveUndo = nil }
            .labelStyle(.iconOnly)
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
        .background(.bar)
      }
    }
    .sheet(item: $sharingTarget) { target in
      NotebookSharingSheet(controller: target.controller, copiesLink: target.copiesLink)
        .personalAccent(savedHex: notebook.account?.preferences.accentColor)
    }
    .sheet(item: $tagTarget) { target in
      tagEditor(target)
        .personalAccent(savedHex: notebook.account?.preferences.accentColor)
    }
    .sheet(item: $nameTarget) { target in
      nameEditor(target)
        .personalAccent(savedHex: notebook.account?.preferences.accentColor)
    }
    .sheet(item: $reviewTarget) { target in
      NotebookConflictReview(controller: target.controller, review: target.review)
        .personalAccent(savedHex: notebook.account?.preferences.accentColor)
    }
    .sheet(isPresented: $showingSettings) {
      settingsSheet
        .personalAccent(savedHex: notebook.account?.preferences.accentColor)
    }
    .sheet(isPresented: $showingAddToToday) {
      AddToTodaySheet()
        .personalAccent(savedHex: notebook.account?.preferences.accentColor)
    }
  }

  private var settingsSheet: some View {
    let account = notebook.account
    return NotebookSettingsSheet(
      account: account,
      savePreference: { key, value in
        guard let account else { throw AccountError.signedOut }
        _ = try await execute(.preference(.setBoolean(key, value)), accountID: account.id)
      },
      connect: {
        showingSettings = false
        Task {
          await notebook.signIn()
          if notebook.account?.id == active?.draft.accountID,
            notebook.pendingAccount == nil, notebook.library.loadState == .ready
          {
            active?.didReconnect()
          }
        }
      },
      signOut: {
        guard let account else { throw AccountError.signedOut }
        do {
          _ = try await execute(.signOut, accountID: account.id)
          showingSettings = false
        } catch {
          if notebook.account == nil {
            showingSettings = false
            actionMessage = String(
              localized: "You're signed out on this iPhone, but session cleanup couldn't finish. Your local drafts are kept.")
          }
          throw error
        }
      }
    ) {
      PersonalAccentColorRow(
        savedHex: account?.preferences.accentColor,
        hasInvalidStoredValue: account?.preferences.hasMalformedAccentColor ?? false
      ) { hex in
        guard let account else { throw AccountError.signedOut }
        _ = try await execute(.preference(.setAccentColor(hex)), accountID: account.id)
      }
    }
    .id(account?.id)
  }

  private var accountSwitchPresented: Binding<Bool> {
    Binding(
      get: { notebook.pendingAccount != nil },
      set: { presented in
        if !presented, notebook.pendingAccount != nil { notebook.keepCurrentNotebook() }
      })
  }

  private func resolveCreation(_ target: NotebookCreationChoiceTarget) {
    Task {
      guard notebook.account?.id == target.controller.draft.accountID,
        notebook.pendingAccount == nil,
        active?.session.viewIdentity == target.controller.session.viewIdentity
      else {
        actionMessage = NotebookModel.message(for: AccountError.accountChanged)
        return
      }
      guard !isPerformingAction else {
        actionMessage = NotebookModel.message(for: NotebookActionError.publicationInProgress)
        return
      }
      isPerformingAction = true
      defer { isPerformingAction = false }
      do {
        try await target.controller.resolveUncertainCreation(
          target.choice, expectedGeneration: target.generation)
        switch target.choice {
        case .publishAsNew:
          await target.controller.publish()
          if let error = target.controller.metadataError { actionMessage = error }
        case .discard:
          let key = target.controller.draft.id.uuidString
          await photoControllers[key]?.stop()
          photoControllers[key] = nil
          sessions[key] = nil
          if activeID == key { activeID = nil }
          compactColumn = .sidebar
        }
      } catch {
        Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
          .error("Creation choice failed: \(String(reflecting: type(of: error)), privacy: .public)")
        actionMessage = NotebookModel.message(for: error)
      }
    }
  }

  @ViewBuilder
  private var accountSwitchSheet: some View {
    if let account = notebook.account, let pending = notebook.pendingAccount {
      NotebookAccountSwitchSheet(
        current: account.login, replacement: pending.login,
        export: {
          try await finishAccountPersistence(account.id)
          return try await notebook.exportCurrentDrafts()
        },
        switchAccount: {
          try await finishAccountPersistence(account.id)
          for photos in photoControllers.values where photos.accountID == account.id {
            await photos.stop()
          }
          activeID = nil
          columnVisibility = .all
          await notebook.acceptPendingAccount()
        },
        keepCurrent: { notebook.keepCurrentNotebook() })
    }
  }

  private var libraryActions: LibraryActions {
    var actions = LibraryActions(
      refresh: { await notebook.refresh() },
      create: { createNote() },
      today: {
        guard canSwitchDocument else { return }
        sharedPreviewGistID = nil
        compactColumn = .detail
        Task { await notebook.showToday() }
      })
    actions.select = { selectRow($0) }
    actions.account = { showingSettings = true }
    actions.reconnect = {
      Task {
        await notebook.signIn()
        if notebook.account?.id == active?.draft.accountID,
          notebook.pendingAccount == nil, notebook.library.loadState == .ready
        {
          active?.didReconnect()
        }
      }
      actions.recoverStatus = {
        Task {
          if notebook.remoteRefreshProblem?.recovery == .reconnect {
            await notebook.signIn()
          } else {
            await notebook.refresh()
          }
        }
      }
    }
    actions.togglePin = { rowID in
      guard let account = notebook.account,
        let id = notebook.searchTargets[rowID]?.gistID
          ?? notebook.cachedLibrary?.gists.first(where: { $0.id == rowID })?.id
      else {
        actionMessage = String(localized: "Save this local draft to GitHub before pinning it.")
        return
      }
      run(
        .preference(.setPinned(gistID: id, pinned: !account.preferences.pinnedGists.contains(id))),
        accountID: account.id)
    }
    actions.toggleArchive = { rowID in
      guard let account = notebook.account,
        let id = notebook.searchTargets[rowID]?.gistID
          ?? notebook.cachedLibrary?.gists.first(where: { $0.id == rowID })?.id,
        let gist = notebook.cachedLibrary?.gists.first(where: { $0.id == id })
      else {
        actionMessage = String(
          localized: "A recovery or unpublished draft cannot be archived on GitHub.")
        return
      }
      run(.archive(gistID: id, archived: !gist.isArchived), accountID: account.id)
    }
    actions.delete = { rowID in
      guard let target = notebook.libraryDeletionTarget(for: rowID) else {
        actionMessage = String(localized: "Only a gist you own on GitHub can be deleted.")
        return
      }
      libraryDeletionRowID = rowID
      deletionTarget = target
    }
    if let rowID = libraryDeletionRowID, let target = deletionTarget {
      actions.deletionConfirmation = .init(
        rowID: rowID, title: target.title,
        confirm: { run(.delete(gistID: target.id), accountID: target.accountID) },
        dismiss: {
          deletionTarget = nil
          libraryDeletionRowID = nil
        })
    }
    return actions
  }

  private var searchInput: SearchInput {
    SearchInput(
      query: notebook.library.query, tags: notebook.library.selectedTagIDs,
      collection: notebook.library.collection)
  }

  private func note(
    _ controller: NotebookSessionController, availableWidth: CGFloat
  ) -> some View {
    Group {
      if let photos = photoControllers[controller.draft.id.uuidString] {
        NotebookPhotoHost(controller: photos) {
          noteScreen(controller, photos: photos, availableWidth: availableWidth)
        }
      } else {
        ContentUnavailableView(
          "This note couldn't be prepared", systemImage: "exclamationmark.circle",
          description: Text(
            "Return to the Library and open it again. Your local draft is unchanged."))
      }
    }
  }

  private func noteScreen(
    _ controller: NotebookSessionController, photos: NotebookPhotoController,
    availableWidth: CGFloat
  ) -> some View {
    let mode = Binding(
      get: {
        if let sharedPreviewGistID, sharedPreviewGistID == controller.draft.gistID {
          return NoteMode.reading
        }
        return layout.presentedMode(
          availableWidth: availableWidth, sessionMode: controller.mode,
          isEditing: controller.session.isEditing,
          canEdit: controller.document.chrome.access.canEdit)
      },
      set: {
        sharedPreviewGistID = nil
        layout.select($0)
        if $0 != .split { controller.mode = $0 }
      })
    return NoteScreen(
      document: controller.document.chrome, mode: mode,
      saveState: controller.saveState, actions: noteActions(controller),
      allowsSplit: NotebookLayoutPreferences.allowsSplit(availableWidth: availableWidth),
      isSidebarHidden: columnVisibility == .detailOnly
    ) {
      NotebookPhotoSurface(controller: photos, isSource: true) {
        MarkdownEditorView(
          session: controller.session,
          insertPhoto: { photos.choosePhoto() },
          canInsertPhoto: photos.canChoosePhoto,
          intelligence: { presentIntelligence(controller) })
      }
    } preview: {
      NotebookPhotoSurface(
        controller: photos, isSource: false, showsAttachments: mode.wrappedValue != .split
      ) {
        preview(controller)
      }
    }
    .toolbar {
      if isGitHubStatusVisible, controller.remoteInspectionStatus != .idle {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
          GitHubStatusControl(state: controller.remoteInspectionStatus) {
            Task {
              if controller.remoteInspectionProblem?.recovery == .reconnect {
                await notebook.signIn()
                guard notebook.account?.id == controller.draft.accountID,
                  notebook.pendingAccount == nil
                else { return }
                controller.didReconnect()
              }
              await controller.inspectRemoteChanges()
            }
          }
          .id(controller.session.viewIdentity)
        }
        .sharedBackgroundVisibility(.hidden)
      }
    }
    .task(id: controller.draft.id) { await controller.inspectRemoteChanges() }
    .task(id: SourcePresentation(
      session: controller.session.viewIdentity, mode: mode.wrappedValue,
      phase: scenePhase, width: availableWidth)
    ) {
      sourceDiagnostics.record(
        controller.session, mode: mode.wrappedValue, phase: String(describing: scenePhase),
        stage: .requested)
      do {
        try await Task.sleep(for: .milliseconds(650))
      } catch is CancellationError {
        return
      } catch {
        Logger(subsystem: "dev.gistpad.GistPad", category: "SourcePresentation")
          .error("Source diagnostic timing failed: \(String(reflecting: type(of: error)), privacy: .public)")
        return
      }
      sourceDiagnostics.record(
        controller.session, mode: mode.wrappedValue, phase: String(describing: scenePhase),
        stage: .settled)
    }
    .onDisappear {
      sourceDiagnostics.record(
        controller.session, mode: mode.wrappedValue, phase: String(describing: scenePhase),
        stage: .disappeared)
    }
    .onChange(of: NotebookLayoutPreferences.allowsSplit(availableWidth: availableWidth)) { _, allows in
      if !allows, layout.preferredMode == .split, controller.session.isEditing {
        controller.mode = .source
      }
    }
  }

  private func preview(_ controller: NotebookSessionController) -> some View {
    SessionPreview(
      session: controller.session, allowsMutations: controller.document.chrome.access.canEdit,
      openWikilink: { target in
        if let note = notebook.library.snapshot.notes.first(where: {
          $0.title.localizedStandardCompare(target) == .orderedSame
        }) {
          open(gistID: note.id)
        } else {
          actionMessage = String(localized: "No note with that title is in your library.")
        }
      })
      .id(controller.session.viewIdentity)
  }

  private struct SearchInput: Equatable {
    let query: String
    let tags: Set<String>
    let collection: LibraryCollection
  }

  private struct SourcePresentation: Hashable {
    let session: UUID
    let mode: NoteMode
    let phase: ScenePhase
    let width: CGFloat
  }

  private struct AutosaveInput: Equatable {
    let foreground: Bool
    let requests: [String: NotebookSessionController.AutosaveRequest]
  }

  private var autosaveInput: AutosaveInput {
    AutosaveInput(
      foreground: scenePhase == .active,
      requests: sessions.mapValues(\.autosaveRequest))
  }

  private func noteActions(_ controller: NotebookSessionController) -> NoteActions {
    var actions = NoteActions()
    actions.focus = {
      withAnimation(reduceMotion ? nil : .snappy) {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
      }
    }
    actions.save = { publish(controller) }
    actions.reviewChanges = {
      do {
        reviewTarget = .init(controller: controller, review: try controller.reviewContext())
      } catch { actionMessage = NotebookModel.message(for: error) }
    }
    actions.retry = {
      if case .localFailure = controller.saveState {
        controller.retryLocalSave()
      } else {
        publish(controller)
      }
    }
    actions.reconnect = {
      Task {
        await notebook.signIn()
        if notebook.account?.id == controller.draft.accountID,
          notebook.pendingAccount == nil, notebook.library.loadState == .ready
        {
          controller.didReconnect()
        }
      }
    }
    if let gistID = controller.document.gist?.id {
      actions.selectFile = { open(gistID: gistID, filename: $0) }
      actions.tags = {
        tagTarget = NotebookTagTarget(
          accountID: controller.draft.accountID, gistID: gistID,
          selected: Set(controller.document.chrome.tags.map(\.id)),
          canEdit: notebook.account?.id == controller.draft.accountID
            && notebook.pendingAccount == nil && !controller.document.isRecovery)
      }
      if !controller.document.isRecovery {
        actions.togglePin = {
          run(
            .preference(
              .setPinned(
                gistID: gistID, pinned: !controller.document.chrome.isPinned)),
            accountID: controller.draft.accountID)
        }
        actions.toggleStar = {
          run(
            .star(gistID: gistID, starred: !controller.document.chrome.isStarred),
            accountID: controller.draft.accountID)
        }
        if controller.document.chrome.access.canEdit {
          actions.toggleArchive = {
            run(
              .archive(gistID: gistID, archived: !controller.document.chrome.isArchived),
              accountID: controller.draft.accountID)
          }
          actions.delete = {
            libraryDeletionRowID = nil
            deletionTarget = .init(
              id: gistID, accountID: controller.draft.accountID,
              title: controller.document.chrome.title)
          }
          actions.addFile = { requestName(.addFile, controller: controller) }
          actions.renameFile = { requestName(.filename, controller: controller) }
        }
      }
    }
    if controller.document.chrome.access.canEdit, !controller.document.isRecovery {
      actions.rename = { requestName(.title, controller: controller) }
    }
    actions.didChangeMode = { mode in
      if mode == .source {
        controller.session.requestFocusAtContentStart()
      } else if mode == .reading {
        controller.session.textView.resignFirstResponder()
      }
    }
    actions.find = {
      sharedPreviewGistID = nil
      controller.mode = .source
      controller.session.presentFind(replacing: true)
    }
    actions.intelligence = { presentIntelligence(controller) }
    actions.share = { presentSharing(controller, copiesLink: false) }
    actions.copyLink = { presentSharing(controller, copiesLink: true) }
    if !controller.document.isRecovery, let gist = controller.document.gist {
      actions.openInGitHub = {
        do { openURL(try DocumentLinks(gist: gist).githubURL) } catch {
          actionMessage = NotebookModel.message(for: error)
        }
      }
    } else if controller.saveState == .creationUncertain, controller.draft.gistID == nil,
      !controller.document.isRecovery
    {
      actions.openInGitHub = {
        guard let account = notebook.account, account.id == controller.draft.accountID,
          !account.login.isEmpty
        else {
          actionMessage = NotebookModel.message(for: AccountError.accountChanged)
          return
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gist.github.com"
        components.path = "/\(account.login)"
        guard let url = components.url else {
          actionMessage = String(localized: "This account's GitHub Gists page couldn't be opened.")
          return
        }
        openURL(url)
      }
    }
    if controller.saveState == .creationUncertain {
      let generation = controller.session.generation
      actions.publishAsNew = {
        creationChoiceTarget = .init(
          controller: controller, generation: generation, choice: .publishAsNew)
      }
      actions.discardLocalCopy = {
        creationChoiceTarget = .init(
          controller: controller, generation: generation, choice: .discard)
      }
    }
    return actions
  }

  private func open(gistID: String, filename: String? = nil) {
    guard active?.session.isComposing != true, active?.session.writingToolsActive != true else {
      notebook.library.selectedNoteID = active?.document.rowID
      actionMessage = String(
        localized: "Finish composition or Writing Tools before switching notes.")
      return
    }
    sharedPreviewGistID = nil
    let request = UUID()
    openRequest = request
    Task {
      await notebook.open(gistID: gistID, filename: filename)
      guard request == openRequest else { return }
    }
  }

  private func selectRow(_ id: String) {
    guard canSwitchDocument else {
      notebook.library.selectedNoteID = active?.document.rowID
      return
    }
    sharedPreviewGistID = nil
    let request = UUID()
    openRequest = request
    let isPrepared = notebook.beginOpeningRow(id: id)
    compactColumn = .detail
    if isPrepared {
      if let document = notebook.loadedDocument { _ = activatePreparedDocument(document) }
      return
    }
    Task {
      guard request == openRequest, notebook.library.selectedNoteID == id else { return }
      await notebook.openRow(id: id)
    }
  }

  private func activateLoadedDocument() async {
    guard let document = notebook.loadedDocument else { return }
    if activatePreparedDocument(document) { return }
    do {
      let draft = try await notebook.openDraft(for: document)
      guard !Task.isCancelled, notebook.loadedDocument?.id == document.id,
        notebook.account?.id == document.accountID,
        notebook.presentedDocument?.refersToSameFile(as: document) == true
      else { return }
      var prepared = document
      prepared.draft = draft
      _ = activatePreparedDocument(prepared)
    } catch is CancellationError {
      return
    } catch {
      Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
        .error("Draft open failed: \(String(reflecting: type(of: error)), privacy: .public)")
      actionMessage = String(
        localized:
          "This note couldn't be opened with durable local storage. Editing has not started.")
      notebook.library.selectedNoteID = active?.document.rowID
    }
  }

  @discardableResult
  private func activatePreparedDocument(_ document: NotebookDocument) -> Bool {
    guard notebook.account?.id == document.accountID,
      notebook.presentedDocument?.refersToSameFile(as: document) == true
    else { return false }
    let controller: NotebookSessionController
    if let existing = sessions.values.first(where: {
      $0.document.refersToSameFile(as: document)
    }) {
      existing.adoptPresentation(document)
      controller = existing
    } else if let draft = document.draft {
      controller = NotebookSessionController(
        document: document, draft: draft, notebook: notebook)
      sessions[draft.id.uuidString] = controller
    } else {
      return false
    }
    controller.mode = layout.initialMode(isUnpublished: controller.draft.baseContent == nil)
    controller.requestCreationFocus()
    preparePhotos(for: controller)
    activeID = controller.draft.id.uuidString
    // A completed restoration must not reopen detail after returning to Library.
    if notebook.library.selectedNoteID != nil { compactColumn = .detail }
    do {
      try notebook.remember(
        NotebookSelection(
          gistID: controller.draft.gistID, filename: controller.draft.filename,
          draftID: controller.draft.id))
    } catch {
      Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
        .error("Remembering document failed: \(String(reflecting: type(of: error)), privacy: .public)")
      actionMessage = String(
        localized: "This note is open, but its selection couldn't be remembered for next time.")
    }
    return true
  }

  private func publish(_ controller: NotebookSessionController) {
    guard controller.canMutate else {
      actionMessage = String(
        localized: "Finish composition or Writing Tools before saving to GitHub.")
      return
    }
    Task {
      await controller.publish()
      if let error = controller.metadataError { actionMessage = error }
    }
  }

  private func finishLeavingNote(_ controller: NotebookSessionController) {
    Task {
      guard await controller.finishLeavingNote() else { return }
      let id = controller.draft.id.uuidString
      sessions[id] = nil
      if activeID == id { activeID = nil }
      if let photos = photoControllers.removeValue(forKey: id) { await photos.stop() }
    }
  }

  private func presentIntelligence(_ controller: NotebookSessionController) {
    guard !controller.session.isComposing, !controller.session.writingToolsActive else {
      actionMessage = String(
        localized: "Finish composition or Writing Tools before opening Intelligence.")
      return
    }
    let accountID = controller.draft.accountID
    let scope = intelligenceAccountScope
    let identity = controller.session.viewIdentity
    let isCurrent: @MainActor () -> Bool = {
      notebook.account?.id == accountID && notebook.pendingAccount == nil
        && !notebook.isSigningIn && intelligenceAccountScope == scope
        && active?.session.viewIdentity == identity
    }
    intelligence.present(
      session: controller.session, title: controller.document.chrome.title,
      filename: controller.draft.filename, isCurrent: isCurrent,
      revealSource: { range in
        guard isCurrent() else { return }
        guard controller.document.chrome.access.canEdit else {
          actionMessage = String(
            localized: "This note is read-only. Its source reference can't be opened in the editor.")
          return
        }
        let generation = controller.session.generation
        guard Range(range, in: controller.session.text) != nil else {
          actionMessage = String(localized: "This reference no longer matches the note.")
          return
        }
        sharedPreviewGistID = nil
        layout.select(.source)
        controller.mode = .source
        Task { @MainActor in
          await Task.yield()
          guard isCurrent() else { return }
          guard controller.session.generation == generation else {
            actionMessage = String(localized: "This reference no longer matches the note.")
            return
          }
          let view = controller.session.textView
          view.selectedRange = range
          view.layoutIfNeeded()
          view.scrollRangeToVisible(range)
          if !view.becomeFirstResponder() {
            controller.session.inputError = String(localized: "Tap the note to resume writing.")
          }
        }
      })
  }

  private func requestName(_ kind: NotebookNameTarget.Kind, controller: NotebookSessionController) {
    nameTarget = NotebookNameTarget(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      gistID: controller.draft.gistID, filename: controller.draft.filename,
      title: controller.document.chrome.title, kind: kind)
  }

  private func nameEditor(_ target: NotebookNameTarget) -> some View {
    NotebookNameEditor(
      title: target.kind == .title
        ? String(localized: "Rename note")
        : (target.kind == .filename
          ? String(localized: "Rename file") : String(localized: "Add file")),
      fieldTitle: target.kind == .title ? String(localized: "Name") : String(localized: "Filename"),
      initialValue: target.kind == .title
        ? target.title : (target.kind == .filename ? target.filename : ""),
      isFilename: target.kind != .title
    ) { value in
      let action: NotebookAction
      switch target.kind {
      case .title:
        if let gistID = target.gistID {
          action = .rename(gistID: gistID, title: value)
        } else {
          action = .renameLocal(draftID: target.draftID, title: value)
        }
      case .filename:
        guard let gistID = target.gistID else { throw DocumentLinkError.notPublished }
        action = .renameFile(gistID: gistID, filename: target.filename, newFilename: value)
      case .addFile:
        guard let gistID = target.gistID else { throw DocumentLinkError.notPublished }
        action = .addFile(gistID: gistID, filename: value)
      }
      _ = try await execute(action, accountID: target.accountID)
    }
  }

  private func tagEditor(_ target: NotebookTagTarget) -> some View {
    let save: (@MainActor @Sendable ([TagEdit]) async throws -> Void)?
    if target.canEdit {
      save = { edits in
        for edit in edits {
          let operation: PreferenceOperation
          switch edit {
          case .setMembership(let id, let included):
            operation = .setTag(gistID: target.gistID, tagID: id, included: included)
          case .upsert(let tag):
            operation = .upsertTag(id: tag.id, name: tag.name, color: tag.colorHex)
          case .delete(let id):
            operation = .deleteTag(id: id)
          }
          _ = try await execute(.preference(operation), accountID: target.accountID)
        }
      }
    } else {
      save = nil
    }
    return TagEditor(
      tags: notebook.library.snapshot.tags, selectedTagIDs: target.selected, save: save)
  }

  private func run(_ action: NotebookAction, accountID: UUID) {
    Task {
      do { _ = try await execute(action, accountID: accountID) } catch {
        actionMessage = NotebookModel.message(for: error)
      }
    }
  }

  private func execute(_ action: NotebookAction, accountID: UUID) async throws
    -> NotebookActionResult
  {
    guard notebook.account?.id == accountID, notebook.pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    guard !isPerformingAction else { throw NotebookActionError.publicationInProgress }
    isPerformingAction = true
    var locked: [NotebookSessionController] = []
    defer {
      for controller in locked { controller.endDestructiveAction() }
      isPerformingAction = false
    }
    do {
      for controller in sessions.values {
        let requiresLock: Bool = switch action {
        case .delete(let gistID): controller.draft.gistID == gistID
        case .signOut: controller.draft.accountID == accountID
        default: false
        }
        if requiresLock {
          try controller.beginDestructiveAction()
          locked.append(controller)
        }
      }
      for controller in sessions.values {
        guard await controller.waitForLocalSave() else {
          throw NotebookEditError.localPersistenceFailed
        }
      }
      let result = try await notebook.perform(action)
      switch result {
      case .signedOut:
        let keys = sessions.filter { $0.value.draft.accountID == accountID }.map(\.key)
        for key in keys {
          sessions[key] = nil
          await photoControllers[key]?.stop()
          photoControllers[key] = nil
        }
        activeID = nil
        compactColumn = .sidebar
      case .gist(let gist, _), .archived(let gist, _):
        for controller in sessions.values where controller.draft.gistID == gist.id {
          try await controller.refreshMetadata(gist: gist)
        }
        if case .archived(_, let undo) = result { archiveUndo = undo }
        if case .undoArchive = action { archiveUndo = nil }
      case .account:
        for controller in sessions.values where controller.draft.accountID == accountID {
          try await controller.refreshMetadata()
        }
      case .draft(let draft, let gist):
        if let controller = sessions[draft.id.uuidString] {
          try await controller.refreshMetadata(gist: gist)
        }
      case .deleted(_, let disposition):
        for id in disposition.removedDraftIDs {
          sessions[id.uuidString] = nil
          photoControllers[id.uuidString] = nil
        }
        for draft in disposition.retainedDrafts { sessions[draft.id.uuidString]?.markRecovery() }
      case .review:
        break
      case .discardedDraft(let id):
        sessions[id.uuidString] = nil
        await photoControllers[id.uuidString]?.stop()
        photoControllers[id.uuidString] = nil
        if activeID == id.uuidString { activeID = nil }
      }
      return result
    } catch {
      for controller in sessions.values {
        if let id = controller.draft.gistID, notebook.deletedGistIDs.contains(id) {
          controller.markRecovery()
        }
      }
      Logger(subsystem: "dev.gistpad.GistPad", category: "Notebook")
        .error("Note action failed: \(String(reflecting: type(of: error)), privacy: .public)")
      throw error
    }
  }

  private func preparePhotos(for controller: NotebookSessionController) {
    let key = controller.draft.id.uuidString
    let accountID = controller.draft.accountID
    guard photoControllers[key] == nil else { return }
    photoControllers[key] = NotebookPhotoController(
      session: controller, notebook: notebook,
      isCurrent: { [weak activity, weak notebook] in
        activity?.activeID == key && notebook?.account?.id == accountID
      },
      reconnect: { [weak notebook] in
        await notebook?.signIn()
      })
  }

  private func createNote() {
    guard canSwitchDocument else { return }
    sharedPreviewGistID = nil
    Task { await notebook.createNote() }
  }

  private func startToday() {
    guard canSwitchDocument else { return }
    sharedPreviewGistID = nil
    let target = DailyNoteTarget()
    Task { await notebook.startToday(target: target) }
  }

  private struct RouteReadiness: Hashable {
    let requestID: UUID?
    let accountID: UUID?
    let isReady: Bool
    let isEditing: Bool
  }

  private var routeReadiness: RouteReadiness {
    RouteReadiness(
      requestID: routes.pending?.id,
      accountID: notebook.account?.id,
      isReady: !notebook.isStarting && !notebook.isSigningIn && !isPerformingAction
        && notebook.library.loadState != .loading && notebook.pendingAccount == nil
        && !showingSettings && !showingShare && !showingAddToToday
        && sharingTarget == nil && tagTarget == nil && nameTarget == nil
        && deletionTarget == nil && reviewTarget == nil
        && creationChoiceTarget == nil
        && intelligence.target == nil && intelligence.errorMessage == nil
        && actionMessage == nil && notebook.documentError == nil,
      isEditing: active?.session.isComposing == true || active?.session.writingToolsActive == true)
  }

  private func receivePendingRoute() async {
    guard routeReadiness.isReady, !routeReadiness.isEditing,
      let request = routes.pending
    else { return }
    if case .library = request.route {
      if horizontalSizeClass != .regular {
        openRequest = UUID()
        notebook.showLibrary()
        active?.session.textView.resignFirstResponder()
      }
      columnVisibility = .all
      compactColumn = .sidebar
      routes.acknowledge(request.id)
      return
    }
    guard let account = notebook.account else { return }
    sharedPreviewGistID = nil
    switch request.route {
    case .library:
      break
    case .today:
      await notebook.startToday()
    case .newNote:
      await notebook.createNote()
    case .addToToday:
      showingAddToToday = true
    case .note(let gistID, let filename, let shared):
      if shared { sharedPreviewGistID = gistID }
      await notebook.open(gistID: gistID, filename: filename)
      guard !Task.isCancelled, routes.pending?.id == request.id else { return }
      await activateLoadedDocument()
      if shared {
        active?.mode = .reading
        active?.session.textView.resignFirstResponder()
      }
    case .draft(let accountID, let draftID):
      guard accountID == account.id else {
        actionMessage = "This draft belongs to another GitHub account. Switch accounts to open it."
        routes.acknowledge(request.id)
        return
      }
      await notebook.openLocalDraft(id: draftID)
      guard !Task.isCancelled, routes.pending?.id == request.id else { return }
      await activateLoadedDocument()
    }
    guard !Task.isCancelled, routes.pending?.id == request.id else { return }
    if notebook.presentedDocument != nil || notebook.failedOpen != nil {
      compactColumn = .detail
    }
    routes.acknowledge(request.id)
  }

  private var canSwitchDocument: Bool {
    guard active?.session.isComposing != true, active?.session.writingToolsActive != true else {
      actionMessage = String(
        localized: "Finish composition or Writing Tools before switching notes.")
      return false
    }
    return true
  }

  private func presentSharing(_ controller: NotebookSessionController, copiesLink: Bool) {
    Task {
      guard await controller.waitForLocalSave() else {
        actionMessage = NotebookModel.message(for: NotebookEditError.localPersistenceFailed)
        return
      }
      do {
        if let links = try controller.savedLinks(), !links.isSecret,
          !controller.hasUnpublishedChanges
        {
          if copiesLink {
            UIPasteboard.general.url = links.shareURL
            UIAccessibility.post(
              notification: .announcement, argument: String(localized: "Link copied"))
          } else {
            shareURL = links.shareURL
            showingShare = true
          }
        } else {
          sharingTarget = .init(controller: controller, copiesLink: copiesLink)
        }
      } catch {
        actionMessage = NotebookModel.message(for: error)
      }
    }
  }

  private func finishBackgroundSaves() {
    let lease = NotebookBackgroundLease()
    let documents = Array(sessions.values)
    let saving = Task {
      await NotebookLifecycle.saveOnBackground(documents, shouldContinue: { lease.isActive })
      lease.end()
    }
    lease.onExpiration = { saving.cancel() }
  }

  private func finishAccountPersistence(_ accountID: UUID) async throws {
    for controller in sessions.values where controller.draft.accountID == accountID {
      guard !controller.isPublishing, !controller.isApplyingDurableEdit else {
        throw NotebookActionError.publicationInProgress
      }
      guard !controller.session.isComposing, !controller.session.writingToolsActive else {
        throw SourceMutation.MutationError.compositionActive
      }
      guard await controller.waitForLocalSave() else {
        throw NotebookEditError.localPersistenceFailed
      }
    }
  }
}

@MainActor @Observable
private final class NotebookWorkspaceActivity {
  var activeID: String?
}

@MainActor
enum NotebookLifecycle {
  static func saveOnBackground(
    _ documents: [NotebookSessionController],
    shouldContinue: @escaping @MainActor @Sendable () -> Bool
  ) async {
    for document in documents { document.updateAutosave(isForeground: false) }
    for document in documents { _ = await document.waitForLocalSave() }
    for document in documents {
      guard !Task.isCancelled, shouldContinue() else { return }
      await document.publish(reason: .background, shouldContinue: shouldContinue)
    }
  }
}

@MainActor
final class NotebookBackgroundLease {
  private var identifier = UIBackgroundTaskIdentifier.invalid
  private var expired = false
  var onExpiration: (() -> Void)?

  var isActive: Bool { !expired && identifier != .invalid }

  init() {
    identifier = UIApplication.shared.beginBackgroundTask(
      withName: "Save notebook changes"
    ) {
      [weak self] in
      Task { @MainActor in
        Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
          .info("Background save time expired. Local drafts are retained.")
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
