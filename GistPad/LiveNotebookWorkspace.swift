import GistPadEditor
import GistPadInterface
import GistPadSync
import OSLog
import Observation
import SwiftUI

struct LiveNotebookWorkspace: View {
  @Bindable var notebook: NotebookModel
  @State private var sessions: [String: NotebookSessionController] = [:]
  @State private var photoControllers: [String: NotebookPhotoController] = [:]
  @State private var activity = NotebookWorkspaceActivity()
  @State private var openRequest = UUID()
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var actionMessage: String?
  @State private var shareURL: URL?
  @State private var showingShare = false
  @State private var sharingTarget: NotebookSharingTarget?
  @State private var tagTarget: NotebookTagTarget?
  @State private var nameTarget: NotebookNameTarget?
  @State private var deletionTarget: NotebookDeletionTarget?
  @State private var reviewTarget: NotebookConflictTarget?
  @State private var isPerformingAction = false
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  private var active: NotebookSessionController? {
    activeID.flatMap { sessions[$0] }
  }

  private var activeID: String? {
    get { activity.activeID }
    nonmutating set { activity.activeID = newValue }
  }

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      LibraryView(model: notebook.library, actions: libraryActions)
    } detail: {
      NavigationStack {
        if let active {
          note(active)
        } else {
          TodayLanding(summary: notebook.library.today, start: { startToday() })
            .disabled(notebook.account == nil || notebook.isCreating)
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .tint(InterfaceTheme.accent)
    .overlay(alignment: .top) {
      if notebook.isOpeningDocument {
        ProgressView("Opening note")
          .padding()
          .background(.regularMaterial, in: .capsule)
          .allowsHitTesting(false)
      }
    }
    .task { await notebook.start() }
    .task(id: notebook.loadedDocument?.id) {
      if notebook.loadedDocument == nil { activeID = nil } else { await activateLoadedDocument() }
    }
    .task(id: searchInput) { await notebook.search() }
    .onChange(of: notebook.library.selectedNoteID) { _, selected in
      guard let selected, selected != notebook.loadedDocument?.rowID else { return }
      guard canSwitchDocument else {
        notebook.library.selectedNoteID = active?.document.rowID
        return
      }
      Task { await notebook.openRow(id: selected) }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { finishLocalPersistence() }
      if phase == .active { Task { await notebook.updateCalendar() } }
    }
    .onChange(of: notebook.account?.id) { _, accountID in
      Task {
        for photos in photoControllers.values where photos.accountID != accountID {
          await photos.stop()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      Task { await notebook.updateCalendar() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
      Task { await notebook.updateCalendar() }
    }
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
      if let shareURL { NotebookActivitySheet(item: .url(shareURL)) }
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
    .confirmationDialog(
      String(localized: "Delete “\(deletionTarget?.title ?? "")” from GitHub?"),
      isPresented: Binding(
        get: { deletionTarget != nil },
        set: { if !$0 { deletionTarget = nil } }),
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
  }

  private var libraryActions: LibraryActions {
    var actions = LibraryActions(
      refresh: { await notebook.refresh() },
      create: { createNote() },
      today: {
        guard canSwitchDocument else { return }
        Task { await notebook.showToday() }
      })
    actions.reconnect = {
      Task {
        await notebook.signIn()
        if notebook.account?.id == active?.draft.accountID,
          notebook.pendingAccount == nil, notebook.library.loadState == .ready
        {
          active?.didReconnect()
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
    return actions
  }

  private var searchInput: SearchInput {
    SearchInput(
      query: notebook.library.query, tags: notebook.library.selectedTagIDs,
      collection: notebook.library.collection)
  }

  private func note(_ controller: NotebookSessionController) -> some View {
    Group {
      if let photos = photoControllers[controller.draft.id.uuidString] {
        NotebookPhotoHost(controller: photos) { noteScreen(controller, photos: photos) }
      } else {
        ContentUnavailableView(
          "This note couldn't be prepared", systemImage: "exclamationmark.circle",
          description: Text(
            "Return to the Library and open it again. Your local draft is unchanged."))
      }
    }
  }

  private func noteScreen(
    _ controller: NotebookSessionController, photos: NotebookPhotoController
  ) -> some View {
    @Bindable var controller = controller
    return NoteScreen(
      document: controller.document.chrome, mode: $controller.mode,
      saveState: controller.saveState, actions: noteActions(controller)
    ) {
      NotebookPhotoSurface(controller: photos, isSource: true) {
        MarkdownEditorView(session: controller.session)
      }
    } preview: {
      NotebookPhotoSurface(controller: photos, isSource: false) {
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
      }
    }
    .task {
      if controller.mode == .source, controller.draft.baseContent == nil {
        controller.session.textView.becomeFirstResponder()
      }
    }
  }

  private struct SearchInput: Equatable {
    let query: String
    let tags: Set<String>
    let collection: LibraryCollection
  }

  private func noteActions(_ controller: NotebookSessionController) -> NoteActions {
    var actions = NoteActions()
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
        controller.session.textView.becomeFirstResponder()
      } else {
        controller.session.textView.resignFirstResponder()
      }
    }
    actions.share = { presentSharing(controller, copiesLink: false) }
    actions.copyLink = { presentSharing(controller, copiesLink: true) }
    if !controller.document.isRecovery, let gist = controller.document.gist {
      actions.openInGitHub = {
        do { openURL(try DocumentLinks(gist: gist).githubURL) } catch {
          actionMessage = NotebookModel.message(for: error)
        }
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
    let request = UUID()
    openRequest = request
    Task {
      await notebook.open(gistID: gistID, filename: filename)
      guard request == openRequest else { return }
    }
  }

  private func activateLoadedDocument() async {
    guard let document = notebook.loadedDocument else { return }
    if let existing = sessions.values.first(where: {
      $0.draft.accountID == document.accountID
        && ($0.draft.id == document.draft?.id
          || (document.gist?.id != nil && $0.draft.gistID == document.gist?.id
            && $0.draft.filename == document.filename))
    }) {
      preparePhotos(for: existing)
      activeID = existing.draft.id.uuidString
      compactColumn = .detail
      return
    }
    do {
      let draft = try await notebook.openDraft(for: document)
      guard !Task.isCancelled, notebook.loadedDocument?.id == document.id,
        notebook.account?.id == document.accountID
      else { return }
      let controller = NotebookSessionController(
        document: document, draft: draft, notebook: notebook)
      sessions[draft.id.uuidString] = controller
      preparePhotos(for: controller)
      activeID = draft.id.uuidString
      try notebook.remember(
        NotebookSelection(
          gistID: draft.gistID, filename: draft.filename, draftID: draft.id))
      compactColumn = .detail
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
      if case .delete(let gistID) = action {
        for controller in sessions.values where controller.draft.gistID == gistID {
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
      case .gist(let gist, _):
        for controller in sessions.values where controller.draft.gistID == gist.id {
          try await controller.refreshMetadata(gist: gist)
        }
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
    Task { await notebook.createNote() }
  }

  private func startToday() {
    guard canSwitchDocument else { return }
    let target = DailyNoteTarget()
    Task { await notebook.startToday(target: target) }
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

  private func finishLocalPersistence() {
    let lease = LocalPersistenceLease()
    let documents = Array(sessions.values)
    Task {
      for document in documents { _ = await document.waitForLocalSave() }
      lease.end()
    }
  }
}

@MainActor @Observable
private final class NotebookWorkspaceActivity {
  var activeID: String?
}

@MainActor
private final class LocalPersistenceLease {
  private var identifier = UIBackgroundTaskIdentifier.invalid

  init() {
    identifier = UIApplication.shared.beginBackgroundTask(
      withName: "Finish local draft persistence"
    ) {
      [weak self] in
      Task { @MainActor in
        Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
          .error("Background time expired before local persistence finished.")
        self?.end()
      }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
