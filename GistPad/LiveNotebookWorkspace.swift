import GistPadComments
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
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var actionMessage: String?
  @State private var shareURL: URL?
  @State private var showingShare = false
  @State private var sharingTarget: NotebookSharingTarget?
  @State private var tagTarget: NotebookTagTarget?
  @State private var nameTarget: NotebookNameTarget?
  @State private var reviewTarget: NotebookConflictTarget?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var layout = NotebookLayoutPreferences()
  @State private var showingSettings = false
  @State private var showingAddToToday = false
  @State private var intelligence = NotebookIntelligencePresentation()
  @State private var comments: NotebookCommentsPresentation
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.openURL) private var openURL
  @Environment(\.undoManager) private var undoManager
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    notebook: NotebookModel, layout: NotebookLayoutPreferences = NotebookLayoutPreferences(),
    routes: NotebookRouteInbox = .shared
  ) {
    self.notebook = notebook
    self.routes = routes
    _layout = State(initialValue: layout)
    _comments = State(initialValue: NotebookCommentsPresentation(notebook: notebook))
  }

  private var active: NotebookSessionController? { notebook.activeFile }

  private var libraryCollections: Binding<Set<LibraryCollection>> {
    guard let accountID = notebook.account?.id else { return .constant([]) }
    return Binding(
      get: { layout.expandedCollections(accountID: accountID) },
      set: { layout.setExpandedCollections($0, accountID: accountID) })
  }

  private var pinnedExpanded: Binding<Bool> {
    guard let accountID = notebook.account?.id else { return .constant(true) }
    return Binding(
      get: { layout.isPinnedExpanded(accountID: accountID) },
      set: { layout.setPinnedExpanded($0, accountID: accountID) })
  }

  var body: some View {
    workspaceSheets
      .sheet(isPresented: accountSwitchPresented) {
        accountSwitchSheet
      }
      .notebookIntelligence(intelligence)
  }

  private var navigation: some View {
    Group {
      if notebook.account == nil {
        NavigationStack {
          LibraryView(
            model: notebook.library, actions: libraryActions, isSidebar: horizontalSizeClass == .regular,
            expandedCollections: libraryCollections, isPinnedExpanded: pinnedExpanded)
        }
      } else {
        notebookNavigation
      }
    }
  }

  private var libraryProblem: GitHubStatusProblem? {
    if case .problem(let problem) = notebook.remoteRefreshStatus { problem } else { nil }
  }

  private var notebookNavigation: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn
    ) {
      LibraryView(
        model: notebook.library, actions: libraryActions,
        isSidebar: horizontalSizeClass == .regular,
        isTodaySelected: notebook.isTodaySelected,
        problem: libraryProblem,
        expandedCollections: libraryCollections,
        isPinnedExpanded: pinnedExpanded)
        .id(notebook.account?.id)
    } detail: {
      NavigationStack {
        GeometryReader { geometry in
          if let opening = notebook.opening, let failure = opening.failure {
            NotebookFailedOpeningView(opening: opening, message: failure) {
              Task { await notebook.open(opening.request) }
            }
          } else if let active {
            note(active, availableWidth: geometry.size.width)
          } else if let document = notebook.presentedDocument {
            NotebookOpeningView(title: notebook.chrome(for: document).title, document: document)
              .id(document.id)
          } else if let title = notebook.openingTitle {
            NotebookOpeningView(title: title)
              .id(notebook.opening?.rowID ?? notebook.library.selectedNoteID)
          } else {
            NotebookOpeningView(title: String(localized: "Today"))
          }
        }
        .libraryRail(
          isVisible: horizontalSizeClass == .regular && notebook.library.loadState != .signedOut,
          today: notebook.library.today, isTodaySelected: notebook.isTodaySelected,
          create: libraryActions.create, openToday: libraryActions.today)
      }
      .frame(minWidth: comments.isPresented && horizontalSizeClass == .regular ? 320 : 0)
    }
    .navigationSplitViewStyle(.balanced)
    .librarySearch(model: notebook.library)
    .toolbar(removing: comments.isPresented && horizontalSizeClass == .regular ? .sidebarToggle : nil)
    .inspector(isPresented: $comments.isPresented) {
      commentsPanel
        .inspectorColumnWidth(min: 280, ideal: 320, max: 360)
        .presentationDetents(
          dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large],
          selection: Binding(
            get: { dynamicTypeSize.isAccessibilitySize ? .large : comments.detent },
            set: { comments.detent = $0 }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .onDisappear {
          if !comments.isPresented, let previous = comments.sidebarBeforeOpening {
            comments.sidebarBeforeOpening = nil
            columnVisibility = previous
          }
          comments.didDismiss()
        }
    }
    .onChange(of: comments.isPresented) { _, presented in
      if presented, horizontalSizeClass == .regular {
        if comments.sidebarBeforeOpening == nil {
          comments.sidebarBeforeOpening = columnVisibility
        }
        columnVisibility = .detailOnly
      } else if !presented, comments.sidebarBeforeOpening != nil {
        // Dismiss any temporary overlay before restoring the pinned column at native completion.
        columnVisibility = .detailOnly
      }
    }
    .onChange(of: horizontalSizeClass) { _, sizeClass in
      if comments.isPresented, sizeClass == .regular {
        if comments.sidebarBeforeOpening == nil {
          comments.sidebarBeforeOpening = columnVisibility
        }
        columnVisibility = .detailOnly
      }
    }
    .onChange(of: commentCount, initial: true) { _, count in
      if let count {
        notebook.recordCommentCount(
          accountID: count.scope.accountID, gistID: count.scope.gistID, total: count.total)
      }
    }
    .confirmationDialog(
      String(localized: "Choose Comment"),
      isPresented: commentsChoicePresented(inInspector: false),
      titleVisibility: .visible
    ) {
      commentChoices
    }
  }

  private var workspaceNavigationLifecycle: some View {
    navigation
    .task {
      await notebook.start()
      await notebook.publishUnsyncedEdits()
    }
    .task(id: routeReadiness) { await receivePendingRoute() }
    #if DEBUG
    .onChange(of: [active?.draft.id.uuidString, routes.pending?.url.absoluteString], initial: true) {
      presentFixtureSheet()
    }
    #endif
    .onChange(of: active?.document.activationID, initial: true) { didActivate() }
    .onChange(of: active?.draft.id) { previous, _ in
      if let previous, let outgoing = notebook.files[previous] {
        Task { await outgoing.finishLeavingNote() }
      }
    }
    .onChange(of: notebook.library.selectedNoteID) { _, selected in
      if selected == nil, notebook.opening == nil { compactColumn = .sidebar }
    }
    .onChange(of: compactColumn) { previous, current in
      guard previous != current, current == .sidebar else { return }
      if horizontalSizeClass == .compact {
        comments.hide()
        notebook.showLibrary()
        active?.session.textView.resignFirstResponder()
      }
      if let outgoing = active { Task { await outgoing.finishLeavingNote() } }
    }
  }

  /// Prepares a note as it comes into the detail column.
  private func didActivate() {
    guard let active else { return }
    active.mode = layout.initialMode(isUnpublished: active.draft.baseContent == nil)
    comments.activate(active)
    active.requestCreationFocus()
    openRequestedComments()
    // A completed restoration must not reopen detail after returning to Library.
    if notebook.library.selectedNoteID != nil, active.document.revealsDetail {
      compactColumn = .detail
    }
  }

  /// Opens the comments a library row asked for, once its note is the active one.
  private func openRequestedComments() {
    guard let active, comments.requestedRowID == active.document.rowID,
      comments.sessionID == active.session.viewIdentity
    else { return }
    comments.requestedRowID = nil
    comments.open(for: active)
  }

  private var workspaceLifecycle: some View {
    workspaceNavigationLifecycle
    .onChange(of: scenePhase, initial: true) { notebook.isForeground = scenePhase == .active }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { finishBackgroundSaves() }
      if phase == .active {
        Task { await notebook.publishUnsyncedEdits() }
        notebook.updateCalendar()
        Task { await active?.inspectRemoteChanges() }
      }
    }
    .onChange(of: notebook.account, initial: true) {
      NotebookPlatformBootstrap.scheduleRefresh()
    }
    .onChange(of: notebook.pendingAccount?.id) { _, pending in
      NotebookPlatformBootstrap.scheduleRefresh()
      if pending != nil { comments.reset() }
    }
    .onChange(of: notebook.localDrafts) {
      NotebookPlatformBootstrap.scheduleRefresh()
    }
    .onChange(of: notebook.account?.id) { _, accountID in
      comments.reset()
      intelligence.target = nil
      columnVisibility = .all
      if accountID == nil { showingSettings = false }
    }
    .onChange(of: notebook.isSigningIn) { _, signingIn in
      if signingIn {
        comments.reset()
        intelligence.target = nil
      }
    }
    .onChange(of: notebook.isSigningOut) { _, signingOut in
      if signingOut { comments.reset() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      notebook.updateCalendar()
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
      }
    }
    .sheet(item: $sharingTarget) { target in
      NotebookSharingSheet(controller: target.controller, copiesLink: target.copiesLink)
    }
    .sheet(item: $tagTarget) { target in
      tagEditor(target)
    }
    .sheet(item: $nameTarget) { target in
      nameEditor(target)
    }
    .sheet(item: $reviewTarget) { target in
      NotebookConflictReview(controller: target.controller, review: target.review)
    }
    .sheet(isPresented: $showingSettings) {
      settingsSheet
    }
    .sheet(isPresented: $showingAddToToday) {
      AddToTodaySheet()
    }
  }

  private var settingsSheet: some View {
    let account = notebook.account
    return NotebookSettingsSheet(
      account: account,
      savePreference: { key, value in
        guard let account else { throw AccountError.signedOut }
        _ = try await notebook.apply(.preference(.setBoolean(key, value)), accountID: account.id)
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
        _ = try await notebook.apply(.signOut, accountID: account.id)
        showingSettings = false
      }
    ) {
      PersonalAccentColorRow(savedHex: account?.preferences.accentColor) { hex in
        guard let account else { throw AccountError.signedOut }
        _ = try await notebook.apply(.preference(.setAccentColor(hex)), accountID: account.id)
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

  @ViewBuilder
  private var accountSwitchSheet: some View {
    if let account = notebook.account, let pending = notebook.pendingAccount {
      NotebookAccountSwitchSheet(
        current: account.login, replacement: pending.login,
        switchAccount: { try await notebook.acceptPendingAccount() },
        keepCurrent: { notebook.keepCurrentNotebook() })
    }
  }

  var libraryActions: LibraryActions {
    var actions = LibraryActions(
      refresh: { await notebook.refresh() },
      create: { createNote() },
      today: { startToday() })
    actions.select = { selectRow($0) }
    actions.openComments = { rowID in
      guard canSwitchDocument else { return }
      comments.requestedRowID = rowID
      selectRow(rowID)
      openRequestedComments()
    }
    actions.account = { showingSettings = true }
    let reconnect: @MainActor () -> Void = {
      Task {
        await notebook.signIn()
        if notebook.account?.id == active?.draft.accountID,
          notebook.pendingAccount == nil, notebook.library.loadState == .ready
        {
          active?.didReconnect()
        }
      }
    }
    actions.reconnect = reconnect
    actions.recoverStatus = {
      if notebook.writeFailure != nil {
        Task { await recoverWrite() }
        return
      }
      switch (notebook.library.loadState, notebook.remoteRefreshProblem?.recovery) {
      case (.reconnectRequired, _), (_, .reconnect?):
        reconnect()
      default:
        Task { await notebook.refresh() }
      }
    }
    actions.togglePin = { rowID in
      guard let account = notebook.account, let id = notebook.gistID(forRow: rowID) else {
        actionMessage = String(localized: "Save this local draft to GitHub before pinning it.")
        return
      }
      notebook.run(
        .preference(.setPinned(gistID: id, pinned: !account.preferences.pinnedGists.contains(id))),
        accountID: account.id)
    }
    actions.toggleArchive = { rowID in
      guard let account = notebook.account, let id = notebook.gistID(forRow: rowID),
        let gist = notebook.cachedLibrary?.gists.first(where: { $0.id == id })
      else {
        actionMessage = String(
          localized: "A recovery or unpublished draft cannot be archived on GitHub.")
        return
      }
      setArchived(!gist.isArchived, gistID: id, accountID: account.id)
    }
    actions.delete = { rowID in
      guard let target = notebook.libraryDeletionTarget(for: rowID) else {
        actionMessage = String(localized: "This note is no longer available to delete.")
        return
      }
      notebook.run(target.action, accountID: target.accountID)
    }
    return actions
  }

  private func note(
    _ controller: NotebookSessionController, availableWidth: CGFloat
  ) -> some View {
    NotebookPhotoHost(photos: controller.photos) {
      noteScreen(controller, photos: controller.photos, availableWidth: availableWidth)
    }
  }

  private func noteScreen(
    _ controller: NotebookSessionController, photos: NotebookPhotoController,
    availableWidth: CGFloat
  ) -> some View {
    let mode = Binding(
      get: {
        if comments.isPresented, comments.matches(controller.document) {
          return comments.documentMode
        }
        return layout.presentedMode(
          availableWidth: availableWidth, sessionMode: controller.mode,
          isEditing: controller.session.isEditing,
          canEdit: controller.chrome.access.canEdit)
      },
      set: {
        if comments.isPresented, comments.matches(controller.document) {
          comments.documentMode = $0
        } else {
          layout.select($0)
          if $0 != .split { controller.mode = $0 }
        }
        if $0 == .source {
          controller.session.requestFocusAtContentStart()
        } else if $0 == .reading {
          controller.session.textView.resignFirstResponder()
        }
      })
    var chrome = controller.chrome
    if comments.matches(controller.document) {
      chrome.commentCount = comments.conversation?.comments?.count ?? chrome.commentCount
    }
    return NoteScreen(
      document: chrome, mode: mode,
      saveState: controller.saveState, actions: noteActions(controller),
      allowsSplit: !comments.isPresented && NotebookLayoutPreferences.allowsSplit(availableWidth: availableWidth),
      isSidebarHidden: columnVisibility == .detailOnly,
      areCommentsPresented: comments.isPresented && comments.matches(controller.document)
    ) {
      MarkdownEditorView(
        session: controller.session,
        insertPhoto: { comments.performAfterClosing { photos.choosePhoto() } },
        canInsertPhoto: photos.canChoosePhoto,
        intelligence: { comments.performAfterClosing { presentIntelligence(controller) } },
        comments: commentConfiguration(controller),
        onOpenCommentThreads: commentOpener(controller, origin: .source),
        onLinkedCommentIDsChange: { ids in
          guard comments.sessionID == controller.session.viewIdentity else { return }
          comments.sourceLinkedIDs = ids
        },
        onAddComment: commentComposer(controller, origin: .source))
    } preview: {
      preview(controller)
    }
    .toolbar {
      if (notebook.writeAttentionStatus ?? controller.remoteInspectionStatus) != .idle
      {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
          GitHubStatusControl(
            state: notebook.writeAttentionStatus ?? controller.remoteInspectionStatus
          ) {
            Task {
              if notebook.writeFailure != nil {
                await recoverWrite()
                return
              }
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
    .task(id: CommentReadInput(
      session: controller.session.viewIdentity, gistID: controller.document.gist?.id,
      knownTotal: controller.document.gist?.commentCount,
      isReady: notebook.account?.id == controller.draft.accountID
        && notebook.pendingAccount == nil && !notebook.isSigningIn && !notebook.isSigningOut,
      allowsComments: NotebookCommentsPresentation.supports(controller.document),
      showsInline: notebook.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true)
    ) {
      guard notebook.account?.id == controller.draft.accountID, notebook.pendingAccount == nil,
        !notebook.isSigningIn, !notebook.isSigningOut else { return }
      comments.activate(controller)
      await comments.prepareAnnotations(
        for: controller,
        showsInline: notebook.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true)
    }
    .onChange(of: NotebookLayoutPreferences.allowsSplit(availableWidth: availableWidth)) { _, allows in
      if !allows, layout.preferredMode == .split, controller.session.isEditing {
        controller.mode = .source
      }
    }
  }

  private func preview(_ controller: NotebookSessionController) -> some View {
    SessionPreview(
      session: controller.session, allowsMutations: controller.chrome.access.canEdit,
      comments: commentConfiguration(controller),
      onOpenCommentThreads: commentOpener(controller, origin: .reading),
      onLinkedCommentIDsChange: { ids in
        guard comments.sessionID == controller.session.viewIdentity else { return }
        comments.previewLinkedIDs = ids
      },
      onAddComment: commentComposer(controller, origin: .reading),
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

  @ViewBuilder
  private var commentsPanel: some View {
    Group {
      if let conversation = comments.conversation {
        NotebookCommentsInspector(
          conversation: conversation, selectedRootID: comments.selectedRootID,
          threadRevealRevision: comments.threadRevealRevision,
          linkedRootIDs: comments.documentMode == .source
            ? comments.sourceLinkedIDs : comments.previewLinkedIDs,
          isComposerFocused: $comments.isComposerFocused,
          close: { comments.hide() },
          revealPassage: comments.revealPassage,
          didFocus: { comments.detent = .large })
      } else {
        NavigationStack {
          Group {
            if let failure = comments.preparationFailure {
              VStack(alignment: .leading, spacing: 12) {
                Text("Comments couldn’t be opened").font(.headline)
                Text(verbatim: failure)
                Button("Try Again") { comments.retryOpening() }
                  .buttonStyle(.glass)
              }
              .padding(20)
            } else {
              ProgressView("Opening comments")
            }
          }
          .navigationTitle("Comments")
          .navigationSubtitle("All files in this gist")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(role: .close) { comments.hide() }
            }
          }
        }
      }
    }
    .onChange(of: dynamicTypeSize, initial: true) { _, size in
      if size.isAccessibilitySize { comments.detent = .large }
    }
    .confirmationDialog(
      String(localized: "Choose Comment"),
      isPresented: commentsChoicePresented(inInspector: true),
      titleVisibility: .visible
    ) {
      commentChoices
    }
  }

  private func commentsChoicePresented(inInspector: Bool) -> Binding<Bool> {
    Binding(
      get: { comments.isPresented == inInspector && !comments.overlappingIDs.isEmpty },
      set: { presented in
        if !presented, comments.isPresented == inInspector { comments.overlappingIDs = [] }
      })
  }

  @ViewBuilder
  private var commentChoices: some View {
    ForEach(comments.overlappingIDs, id: \.self) { id in
      if let thread = comments.conversation?.threads.first(where: { $0.id == id }),
        let active {
        let author = thread.comment.user?.login ?? String(localized: "Unknown author")
        let excerpt = String(thread.comment.parsedBody.text.prefix(80))
        Button("\(author): \(excerpt)") {
          comments.overlappingIDs = []
          comments.open(for: active, origin: comments.documentMode, rootID: id)
        }
      }
    }
    Button("Cancel", role: .cancel) { comments.overlappingIDs = [] }
  }

  private func commentConfiguration(
    _ controller: NotebookSessionController
  ) -> CommentHighlightConfiguration {
    guard NotebookCommentsPresentation.supports(controller.document),
      comments.matches(controller.document), let conversation = comments.conversation
    else { return .init() }
    return .init(
      quotes: conversation.threads.compactMap(\.quotedPassage),
      selectedCommentID: comments.selectedRootID,
      revealRevision: comments.revealRevision,
      showsInlineComments:
        notebook.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true)
  }

  private func commentOpener(
    _ controller: NotebookSessionController, origin: NoteMode
  ) -> (@MainActor ([Int64]) -> Void)? {
    guard NotebookCommentsPresentation.supports(controller.document) else { return nil }
    return { ids in
      guard comments.sessionID == controller.session.viewIdentity else { return }
      if ids.count == 1, let id = ids.first {
        comments.open(for: controller, origin: origin, rootID: id)
      } else if !ids.isEmpty {
        comments.documentMode = origin
        comments.overlappingIDs = ids
      } else {
        Logger(subsystem: "dev.gistpad.GistPad", category: "Comments")
          .error("A comment activation arrived without a thread identifier.")
      }
    }
  }

  private func commentComposer(
    _ controller: NotebookSessionController, origin: NoteMode
  ) -> (@MainActor (String) -> Void)? {
    guard NotebookCommentsPresentation.supports(controller.document) else { return nil }
    return { selection in
      guard comments.sessionID == controller.session.viewIdentity else { return }
      comments.open(for: controller, origin: origin, quote: selection)
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

  private struct CommentCount: Equatable {
    let scope: NotebookCommentsPresentation.Scope
    let total: Int
  }

  private var commentCount: CommentCount? {
    guard let scope = comments.scope, let total = comments.conversation?.comments?.count else { return nil }
    return .init(scope: scope, total: total)
  }

  private func noteActions(_ controller: NotebookSessionController) -> NoteActions {
    var actions = NoteActions()
    actions.focus = {
      let target: NavigationSplitViewVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
      comments.performAfterClosing {
        withAnimation(reduceMotion ? nil : .snappy) {
          columnVisibility = target
        }
      }
    }
    if NotebookCommentsPresentation.supports(controller.document) {
      actions.comments = {
        if comments.isPresented {
          comments.hide()
        } else {
          comments.open(for: controller)
        }
      }
    }
    actions.save = { publish(controller) }
    actions.reviewChanges = {
      do {
        reviewTarget = .init(controller: controller, review: try controller.reviewContext())
      } catch { actionMessage = error.localizedDescription }
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
          selected: Set(controller.chrome.tags.map(\.id)),
          canEdit: notebook.account?.id == controller.draft.accountID
            && notebook.pendingAccount == nil && !controller.document.isRecovery)
      }
      if !controller.document.isRecovery {
        actions.togglePin = {
          notebook.run(
            .preference(
              .setPinned(
                gistID: gistID, pinned: !controller.chrome.isPinned)),
            accountID: controller.draft.accountID)
        }
        actions.toggleStar = {
          notebook.run(
            .star(gistID: gistID, starred: !controller.chrome.isStarred),
            accountID: controller.draft.accountID)
        }
        if controller.chrome.access.canEdit {
          actions.toggleArchive = {
            setArchived(
              !controller.chrome.isArchived, gistID: gistID,
              accountID: controller.draft.accountID)
          }
          actions.delete = {
            notebook.run(.delete(gistID: gistID), accountID: controller.draft.accountID)
          }
          actions.addFile = { requestName(.addFile, controller: controller) }
          actions.renameFile = { requestName(.filename, controller: controller) }
        }
      }
    }
    if controller.chrome.access.canEdit, !controller.document.isRecovery {
      actions.rename = { requestName(.title, controller: controller) }
    }
    if controller.document.isRecovery || controller.draft.gistID == nil {
      actions.delete = {
        let target = NotebookDeletionTarget(
          id: controller.draft.id.uuidString, accountID: controller.draft.accountID,
          title: controller.chrome.title, localDraft: controller.draft)
        notebook.run(target.action, accountID: target.accountID)
      }
    }
    actions.find = {
      controller.mode = .source
      controller.session.presentFind(replacing: true)
    }
    actions.intelligence = { presentIntelligence(controller) }
    actions.share = { presentSharing(controller, copiesLink: false) }
    actions.copyLink = { presentSharing(controller, copiesLink: true) }
    if !controller.document.isRecovery, let gist = controller.document.gist {
      actions.openInGitHub = {
        do { openURL(try DocumentLinks(gist: gist).githubURL) } catch {
          actionMessage = error.localizedDescription
        }
      }
    }
    actions.intelligence = afterCommentsClose(actions.intelligence)
    actions.tags = afterCommentsClose(actions.tags)
    actions.rename = afterCommentsClose(actions.rename)
    actions.renameFile = afterCommentsClose(actions.renameFile)
    actions.addFile = afterCommentsClose(actions.addFile)
    actions.share = afterCommentsClose(actions.share)
    actions.copyLink = afterCommentsClose(actions.copyLink)
    actions.find = afterCommentsClose(actions.find)
    actions.reviewChanges = afterCommentsClose(actions.reviewChanges)
    actions.delete = afterCommentsClose(actions.delete)
    return actions
  }

  private func open(gistID: String, filename: String? = nil) {
    guard active?.session.isSettled != false else {
      notebook.library.selectedNoteID = active?.document.rowID
      actionMessage = String(
        localized: "Finish composition or Writing Tools before switching notes.")
      return
    }
    Task { await notebook.open(.gist(id: gistID, filename: filename)) }
  }

  private func selectRow(_ id: String) {
    guard canSwitchDocument else {
      notebook.library.selectedNoteID = active?.document.rowID
      return
    }
    notebook.select(rowID: id)
    compactColumn = .detail
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

  private func presentIntelligence(_ controller: NotebookSessionController) {
    guard controller.session.isSettled else {
      actionMessage = String(
        localized: "Finish composition or Writing Tools before opening Intelligence.")
      return
    }
    intelligence.present(
      session: controller.session, title: controller.chrome.title,
      revealSource: { range in
        guard controller.chrome.access.canEdit else {
          actionMessage = String(
            localized: "This note is read-only. Its source reference can't be opened in the editor.")
          return
        }
        let generation = controller.session.generation
        guard Range(range, in: controller.session.text) != nil else {
          actionMessage = String(localized: "This reference no longer matches the note.")
          return
        }
        layout.select(.source)
        controller.mode = .source
        Task { @MainActor in
          await Task.yield()
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
      title: controller.chrome.title, kind: kind)
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
      _ = try await notebook.apply(action, accountID: target.accountID)
    }
  }

  private func tagEditor(_ target: NotebookTagTarget) -> some View {
    let save: (@MainActor @Sendable ([TagEdit]) async throws -> Void)?
    if target.canEdit {
      save = { edits in
        let operations = edits.map { edit -> PreferenceOperation in
          switch edit {
          case .setMembership(let id, let included):
            .setTag(gistID: target.gistID, tagID: id, included: included)
          case .upsert(let tag): .upsertTag(id: tag.id, name: tag.name, color: tag.colorHex)
          case .delete(let id): .deleteTag(id: id)
          }
        }
        _ = try await notebook.apply(.saveTags(operations), accountID: target.accountID)
      }
    } else {
      save = nil
    }
    return TagEditor(
      tags: notebook.library.snapshot.tags, selectedTagIDs: target.selected, save: save)
  }

  private func recoverWrite() async {
    do { try await notebook.retryWrite() } catch {
      actionMessage = error.localizedDescription
    }
    await active?.refreshPersistedState()
  }

  /// Archiving is absolute, so its undo is the opposite archive, registered with the scene so
  /// shake to undo and the undo gesture reverse it.
  private func setArchived(_ archived: Bool, gistID: String, accountID: UUID) {
    notebook.run(.archive(gistID: gistID, archived: archived), accountID: accountID)
    undoManager?.registerUndo(withTarget: notebook) { _ in
      setArchived(!archived, gistID: gistID, accountID: accountID)
    }
    undoManager?.setActionName(
      archived ? String(localized: "Archive") : String(localized: "Unarchive"))
  }

  private func createNote() {
    guard canSwitchDocument else { return }
    Task { await notebook.open(.new) }
  }

  private func startToday() {
    guard canSwitchDocument else { return }
    compactColumn = .detail
    let target = DailyNoteTarget()
    Task { await notebook.open(.today(target)) }
  }

  private struct RouteReadiness: Hashable {
    let route: NotebookRoute?
    let accountID: UUID?
    let isReady: Bool
    let isEditing: Bool
  }

  private var routeReadiness: RouteReadiness {
    RouteReadiness(
      route: routes.pending,
      accountID: notebook.account?.id,
      isReady: !notebook.isStarting && !notebook.isSigningIn && !notebook.isApplying
        && notebook.library.loadState != .loading && notebook.pendingAccount == nil
        && !showingSettings && !showingShare && !showingAddToToday
        && sharingTarget == nil && tagTarget == nil && nameTarget == nil
        && reviewTarget == nil
        && intelligence.target == nil
        && actionMessage == nil && notebook.documentError == nil,
      isEditing: active?.session.isSettled == false)
  }

  #if DEBUG
  /// Presents a fixture launch's `--sheet` once its note is open.
  private func presentFixtureSheet() {
    guard let sheet = FixtureLaunch.pendingSheet, routes.pending == nil, let active else { return }
    FixtureLaunch.pendingSheet = nil
    let actions = noteActions(active)
    switch sheet {
    case .settings: showingSettings = true
    case .tags: actions.tags?()
    case .intelligence: actions.intelligence()
    case .comments: actions.comments?()
    case .today: break
    }
  }
  #endif

  private func receivePendingRoute() async {
    guard routeReadiness.isReady, !routeReadiness.isEditing,
      let route = routes.pending, let account = notebook.account
    else { return }
    switch route {
    case .today:
      await notebook.open(.today())
    case .addToToday:
      showingAddToToday = true
    case .note(let gistID, let filename):
      await notebook.open(.gist(id: gistID, filename: filename))
    case .draft(let accountID, let draftID):
      guard accountID == account.id else {
        actionMessage = "This draft belongs to another GitHub account. Switch accounts to open it."
        routes.clear()
        return
      }
      await notebook.open(.draft(id: draftID))
    }
    guard !Task.isCancelled, routes.pending == route else { return }
    if notebook.presentedDocument != nil || notebook.opening?.failure != nil {
      compactColumn = .detail
    }
    routes.clear()
  }

  private var canSwitchDocument: Bool {
    guard active?.session.isSettled != false else {
      actionMessage = String(
        localized: "Finish composition or Writing Tools before switching notes.")
      return false
    }
    return true
  }

  private func presentSharing(_ controller: NotebookSessionController, copiesLink: Bool) {
    Task {
      guard await controller.waitForLocalSave() else {
        actionMessage = NotebookEditError.localPersistenceFailed.localizedDescription
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
        actionMessage = error.localizedDescription
      }
    }
  }

  private func finishBackgroundSaves() {
    let lease = NotebookBackgroundLease()
    let documents = Array(notebook.files.values)
    let saving = Task {
      await NotebookLifecycle.saveOnBackground(documents, shouldContinue: { lease.isActive })
      lease.end()
    }
    lease.onExpiration = { saving.cancel() }
  }
}

@MainActor
enum NotebookLifecycle {
  static func saveOnBackground(
    _ documents: [NotebookSessionController],
    shouldContinue: @escaping @MainActor @Sendable () -> Bool
  ) async {
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
