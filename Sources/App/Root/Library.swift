import AuthenticationServices
import Foundation
import Comments
import Editor
import Interface
import Sync
import OSLog
import Observation

/// The last GitHub write that failed. A newer failure replaces it, and Retry runs it again.
struct UnsentChange {
  enum Operation {
    case change(Change)
    case file(draftID: UUID)
  }

  let operation: Operation
  let accountID: UUID
  let recovery: RemoteReadProblem.Recovery
}

@MainActor @Observable
final class Library {
  let state = LibraryState()
  private(set) var account: Account?
  private(set) var pendingAccount: Account?
  private(set) var loadedFile: File?
  private(set) var isSigningIn = false
  private(set) var isSigningOut = false
  /// Launch is restoring the account and this iPhone's drafts. Links wait for it, not for GitHub.
  private(set) var isStarting = false
  /// The file opening in the detail column, until it's presented or fails.
  private(set) var opening: Opening?
  private(set) var localDrafts: [Draft] = []
  /// Counts drafts recorded in memory, so a local read that started earlier knows it's stale.
  private var localDraftRecords = 0
  private(set) var cachedLibrary: CachedLibrary?
  private(set) var isCreating = false
  /// The one message the app shows in an alert, such as a failed open or change.
  var openError: String?
  var isShowingError: Bool {
    get { openError != nil }
    set { if !newValue { openError = nil } }
  }
  private(set) var remoteRefreshProblem: RemoteReadProblem?
  private(set) var isRefreshingRemote = false
  private(set) var unsentChange: UnsentChange?
  /// The files opened this session, by draft. Returning to one keeps its caret, scroll and undo.
  private(set) var sessions: [UUID: FileSession] = [:]
  /// Autosave runs only while the app is in the foreground.
  var isForeground = false
  private(set) var isApplying = false

  @ObservationIgnored private let sync: GitHubSync
  @ObservationIgnored private let lastOpened: LastOpened
  @ObservationIgnored private var libraryRequest = UUID()
  @ObservationIgnored private var refreshedAt: Date?
  @ObservationIgnored private var fileRequest = UUID()
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Library")

  init(
    sync: GitHubSync, lastOpened: LastOpened = LastOpened()
  ) {
    self.sync = sync
    self.lastOpened = lastOpened
  }

  var unsentChangeStatus: GitHubStatusState? {
    guard let unsentChange, account?.id == unsentChange.accountID else { return nil }
    // Pins, tags and settings are saved to the GistPad account, not GitHub.
    let (message, detail): (String, String?) =
      switch (unsentChange.operation, unsentChange.recovery) {
      case (_, .reconnect): (AccountError.reconnectGitHub.localizedDescription, nil)
      case (.file, _):
        (
          String(localized: "This file didn't reach GitHub."),
          String(localized: "Your changes are saved on this iPhone.")
        )
      case (.change(.preferences), _):
        (String(localized: "This change wasn't saved."), nil)
      case (.change, _): (String(localized: "This change didn't reach GitHub."), nil)
      }
    return RemoteReadProblem(message: message, recovery: unsentChange.recovery)
      .status(heading: String(localized: "Couldn't sync"), detail: detail)
  }

  // A failed GitHub-backed write outranks read problems, because it means local changes didn't reach GitHub.
  var remoteRefreshStatus: GitHubStatusState {
    if let status = unsentChangeStatus { return status }
    if let problem = remoteRefreshProblem, cachedLibrary != nil || !localDrafts.isEmpty {
      return problem.status(
        heading: String(localized: "Couldn't update your gists"),
        detail: String(localized: "Your gists on this iPhone are unchanged."))
    }
    return isRefreshingRemote
      ? .checking(operation: String(localized: "Checking GitHub for changes")) : .idle
  }

  var visibleFile: File? {
    if let opening { return opening.failure == nil ? cachedFile(rowID: opening.rowID) : nil }
    guard let selected = state.selectedID else { return loadedFile }
    if loadedFile?.rowID == selected { return loadedFile }
    return cachedFile(rowID: selected)
  }

  /// The editor for the file in the detail column.
  var activeSession: FileSession? {
    guard let file = visibleFile else { return nil }
    return sessions.values.first { $0.file.refersToSameFile(as: file) }
  }

  var openingTitle: String? {
    if let opening { return opening.title }
    guard let selected = state.selectedID, selected != loadedFile?.rowID else {
      return nil
    }
    return placeholder(for: request(forRow: selected)).title
  }

  @discardableResult
  func beginOpeningRow(id: String) -> Bool {
    guard account != nil, pendingAccount == nil else {
      openError = String(localized: "Reconnect GitHub to open this gist.")
      return false
    }
    fileRequest = UUID()
    openError = nil
    if let file = cachedFile(rowID: id), file.draft != nil {
      present(file)
      return true
    }
    opening = placeholder(for: request(forRow: id))
    state.selectedID = id
    return false
  }

  /// Opens a library row, at once when its file is already on this iPhone.
  func select(rowID id: String) {
    guard !beginOpeningRow(id: id), opening?.rowID == id else { return }
    let request = fileRequest
    Task {
      guard request == fileRequest else { return }
      await openRow(id: id)
    }
  }

  /// What deleting a row removes: a copy that's only on this iPhone, one day of the daily notes
  /// gist, or the whole gist. Rows the account doesn't own can't be deleted.
  func deletion(forRow rowID: String) -> Change? {
    guard account != nil, pendingAccount == nil else { return nil }
    let target = rowSelection(for: rowID)
    let draft = target?.draftID.flatMap { id in localDrafts.first { $0.id == id } }
    if let draft,
      draft.gistID.flatMap({ gistID in cachedLibrary?.gists.contains(where: { $0.id == gistID }) }) != true
    {
      return .discardLocalCopy(draftID: draft.id, generation: draft.generation)
    }
    let gistID = target?.gistID ?? draft?.gistID ?? rowID
    guard let gist = cachedLibrary?.owned.first(where: { $0.id == gistID }) else { return nil }
    if gist.isDailyNote, let filename = target?.filename {
      return .deleteFile(gistID: gist.id, filename: filename)
    }
    return .delete(gistID: gist.id)
  }

  func gistID(forRow rowID: String) -> String? {
    if cachedLibrary?.gists.contains(where: { $0.id == rowID }) == true { return rowID }
    return state.gists.first { $0.id == rowID && $0.isDailyNote }?.gistID
  }

  private func rowSelection(for rowID: String) -> FileReference? {
    if let id = UUID(uuidString: rowID), let draft = localDrafts.first(where: { $0.id == id }) {
      return .init(gistID: draft.gistID, filename: draft.filename, draftID: id)
    }
    if let row = state.gists.first(where: { $0.id == rowID }),
      let gistID = row.gistID, let filename = row.filename
    {
      return .init(gistID: gistID, filename: filename, draftID: nil)
    }
    return nil
  }

  func cachedFile(rowID: String) -> File? {
    if let target = rowSelection(for: rowID) {
      if let draftID = target.draftID, let draft = localDrafts.first(where: { $0.id == draftID }) {
        return localFile(draft, rowID: rowID)
      }
      if let gistID = target.gistID {
        return cachedFile(gistID: gistID, filename: target.filename, rowID: rowID)
      }
      return nil
    }
    return cachedFile(gistID: rowID, rowID: rowID)
  }

  private func cachedFile(
    gistID: String, filename: String? = nil, rowID: String? = nil
  ) -> File? {
    guard let account, pendingAccount == nil else { return nil }
    let gist = cachedLibrary?.gists.first { $0.id == gistID }
    let selectedFilename: String?
    if let filename {
      selectedFilename = filename
    } else if let gist {
      guard gist.truncated != true || gist.isDailyNote else { return nil }
      selectedFilename = gist.isDailyNote ? DailyNote.filename() : gist.defaultMarkdownFilename
    } else {
      let candidates = localDrafts.filter { $0.gistID == gistID }
      selectedFilename = candidates.count == 1 ? candidates.first?.filename : nil
    }
    guard let selectedFilename, selectedFilename.hasSuffix(".md") else { return nil }
    if let draft = localDrafts.first(where: {
      $0.accountID == account.id && $0.gistID == gistID && $0.filename == selectedFilename
    }) {
      return localFile(draft, rowID: rowID)
    }
    guard let gist, let text = cachedLibrary?.content(gist: gist, filename: selectedFilename) else {
      return nil
    }
    var file = File(
      accountID: account.id, gist: gist, filename: selectedFilename, text: text)
    file.libraryRowID = rowID
    return file
  }

  private func localFile(_ draft: Draft, rowID: String?) -> File {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
    var file = File(
      draft: draft, gist: gist,
      isRecovery: draft.gistID != nil && gist == nil)
    file.libraryRowID = rowID
    return file
  }

  private func request(forRow id: String) -> Opening.Request {
    let target = rowSelection(for: id)
    // A file that never reached GitHub only exists on this iPhone.
    if let draftID = target?.draftID,
      target?.gistID == nil
        || localDrafts.contains(where: { $0.id == draftID && $0.baseContent == nil })
    {
      return .draft(id: draftID, rowID: id)
    }
    return .gist(id: target?.gistID ?? id, filename: target?.filename, rowID: id)
  }

  private func placeholder(for request: Opening.Request) -> Opening {
    let (rowID, title): (String, String?) =
      switch request {
      case .gist(let id, _, let rowID):
        (rowID ?? id, cachedLibrary?.gists.first { $0.id == id }?.displayName)
      case .draft(let id, let rowID):
        (rowID ?? id.uuidString, localDrafts.first { $0.id == id }?.description)
      case .today(let target, _): ("today/\(target.filename)", String(localized: "Today"))
      case .new: ("new", String(localized: "Untitled"))
      }
    return .init(
      request: request, rowID: rowID,
      title: state.gists.first { $0.id == rowID }?.title ?? title
        ?? String(localized: "Gist"))
  }

  private func present(_ file: File) {
    var file = file
    file.libraryRowID = unfilteredRowID(for: file)
    opening = nil
    loadedFile = file
    state.selectedID = file.rowID
    if file.isRecovery { openError = Self.recoveryMessage }
    remember(file.selection)
    guard let draft = file.draft else { return }
    if let session = sessions.values.first(where: { $0.file.refersToSameFile(as: file) }) {
      session.adoptPresentation(file)
    } else {
      sessions[draft.id] = FileSession(file: file, draft: draft, library: self)
    }
  }

  private func unfilteredRowID(for file: File) -> String? {
    state.gists.first {
      $0.id == file.draft?.id.uuidString
        || ($0.gistID != nil && $0.gistID == file.selection.gistID
          && ($0.filename == nil || $0.filename == file.filename))
    }?.id
  }

  private func recordLocalDraft(_ draft: Draft) {
    localDraftRecords += 1
    localDrafts.removeAll { $0.id == draft.id }
    localDrafts.append(draft)
    projectLibrary()
    updateToday()
  }

  private func updateLibraryExcerpt(for draft: Draft) {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
    let isDaily = gist?.isDailyNote == true
      || draft.description == DailyNote.gistDescription
    if isDaily, DailyNote.date(filename: draft.filename) == nil { return }
    if let gist, !gist.isDailyNote, draft.filename != gist.defaultMarkdownFilename { return }
    let rowID =
      if let gist, gist.isDailyNote, owns(gist) {
        "\(gist.id)/\(draft.filename)"
      } else { gist?.id ?? draft.id.uuidString }
    guard let index = state.gists.firstIndex(where: { $0.id == rowID }) else {
      projectLibrary()
      return
    }
    if state.gists[index].gistID == nil {
      state.gists[index].updatedAt = draft.updatedAt
    }
    Self.updateLibraryContent(&state.gists[index], text: draft.text)
  }

  private static func updateLibraryContent(_ item: inout GistItem, text: String?) {
    if item.isDailyNote {
      item.progress = text.map(TaskProgress.init(markdown:))
      item.isOverdue = item.dailyDate.map {
        $0 < Calendar.current.startOfDay(for: .now) && (item.progress?.remaining ?? 0) > 0
      } ?? false
    }
  }

  func start() async {
    guard !isStarting, !isSigningOut else { return }
    isStarting = true
    defer { isStarting = false }
    let request = UUID()
    libraryRequest = request
    state.loadState = .loading
    do {
      let restored = try await sync.connectedAccount()
      guard request == libraryRequest else { return }
      guard let restored else {
        state.loadState = .signedOut
        return
      }
      account = restored
      try await reloadLocalState(accountID: restored.id, discardAbandonedBlanks: true)
      isStarting = false
      await refresh()
      await restoreLastOpened()
    } catch is CancellationError {
      if request == libraryRequest {
        state.loadState = account == nil ? .signedOut : .ready
      }
    } catch {
      guard request == libraryRequest else { return }
      report(error, operation: "restore")
      state.loadState = .failed(message: error.localizedDescription)
    }
  }

  func signIn() async {
    guard !isSigningIn, !isSigningOut else { return }
    isSigningIn = true
    let previousState = state.loadState
    defer { isSigningIn = false }
    do {
      let signedIn = try await sync.signIn()
      libraryRequest = UUID()
      if let account, account.id != signedIn.id {
        pendingAccount = signedIn
        state.loadState = .reconnectRequired(
          message: String(
            localized:
              "A different GitHub account signed in. Keep the current account or switch to it."
          ))
        return
      }
      account = signedIn
      pendingAccount = nil
      try await reloadLocalState(accountID: signedIn.id, discardAbandonedBlanks: true)
      await refresh()
      await restoreLastOpened()
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      state.loadState = previousState
    } catch is CancellationError {
      state.loadState = previousState
    } catch {
      libraryRequest = UUID()
      report(error, operation: "sign-in")
      state.loadState = .reconnectRequired(message: error.localizedDescription)
    }
  }

  /// Switches to the account that just signed in, once every open file is saved on this iPhone.
  func switchAccount() async throws {
    guard let pendingAccount else { return }
    for session in sessions.values {
      guard !session.isPublishing, !session.isApplyingDurableEdit else {
        throw ChangeError.publicationInProgress
      }
      guard session.editor.isSettled else { throw Edit.MutationError.compositionActive }
      guard await session.waitForLocalSave() else { throw EditError.localPersistenceFailed }
    }
    guard self.pendingAccount == pendingAccount else { return }
    reset(to: pendingAccount)
    do {
      try await reloadLocalState(accountID: pendingAccount.id, discardAbandonedBlanks: true)
    } catch {
      report(error, operation: "reload-local")
      openError = error.localizedDescription
    }
    await refresh()
    await restoreLastOpened()
  }

  func keepCurrentAccount() {
    pendingAccount = nil
    state.loadState = .reconnectRequired(
      message: String(
        localized:
          "Your drafts are kept on this iPhone. Reconnect the original account to publish them."
      ))
  }

  /// A new day moves Today and makes yesterday's unfinished tasks overdue.
  func updateCalendar() {
    projectLibrary()
    updateToday()
  }

  // Supabase only supplies preferences, so GitHub reads keep going when its refresh fails. A missing GitHub token still needs reconnecting.
  private func refreshedAccount() async throws -> Account {
    do {
      return try await sync.refreshAccount()
    } catch {
      if error is CancellationError || (error as? AccountError) == .reconnectGitHub { throw error }
      guard let connected = try await sync.connectedAccount() else { throw error }
      return connected
    }
  }

  /// Refreshes as the app comes back, like the web on focus: when the last refresh failed or was
  /// cut off by leaving, or its list is more than five minutes old.
  func refreshOnReturn() async {
    guard account != nil, !isStarting else { return }
    if remoteRefreshProblem == nil, !isRefreshingRemote, let refreshedAt,
      refreshedAt.timeIntervalSinceNow > -5 * 60
    {
      return
    }
    await refresh()
  }

  func refresh() async {
    guard pendingAccount == nil, !isSigningOut else { return }
    guard let account else {
      await start()
      return
    }
    let request = UUID()
    libraryRequest = request
    let previousState: LibraryLoadState = state.loadState == .loading ? .ready : state.loadState
    isRefreshingRemote = true
    // A retry shows as checking instead of the problem it may be about to clear.
    remoteRefreshProblem = nil
    defer {
      if request == libraryRequest { isRefreshingRemote = false }
    }
    state.loadState = .loading
    do {
      let refreshed = try await refreshedAccount()
      guard refreshed.id == account.id else { throw AccountError.accountChanged }
      async let ownedGists = sync.gists(accountID: account.id)
      async let starredGists = sync.starredGists(accountID: account.id)
      let (owned, starred) = try await (ownedGists, starredGists)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      try await sync.cacheLibrary(
        owned: owned, starred: starred, account: refreshed, keeping: openGistIDs)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      self.account = refreshed
      state.loadState = .ready
      await refreshToday(in: owned, accountID: account.id)
      try await reloadLocalState(accountID: account.id)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      refreshedAt = .now
    } catch {
      guard request == libraryRequest else { return }
      // A failed refresh leaves the list stale, so returning to the app tries again.
      refreshedAt = nil
      // A request that only timed out or lost its connection keeps your gists on screen without
      // a problem, and the next refresh tries again. With nothing cached, the failure explains itself.
      let wasDropped = (error as? URLError).map {
        [URLError.Code.timedOut, .networkConnectionLost].contains($0.code)
      } ?? false
      guard let problem = RemoteRead.problem(for: error), !(wasDropped && cachedLibrary != nil)
      else {
        state.loadState = previousState
        return
      }
      report(error, operation: "refresh")
      remoteRefreshProblem = problem
      state.loadState =
        problem.recovery == .reconnect
        ? .reconnectRequired(message: error.localizedDescription)
        : .failed(message: error.localizedDescription)
    }
  }

  /// GitHub lists gists without their text, so a refresh reads today's file whenever the Daily
  /// notes gist changed it. The Today button and today's row then count the tasks of a day started
  /// on the web. A failed read leaves what the phone had.
  private func refreshToday(in owned: [Gist], accountID: UUID) async {
    let filename = DailyNote.filename()
    guard let daily = owned.first(where: \.isDailyNote), daily.files[filename] != nil,
      cachedLibrary?.currentContent(gist: daily, filename: filename) == nil
    else { return }
    _ = try? await sync.content(gist: daily, filename: filename, accountID: accountID)
  }

  /// Drafts a refresh keeps even when GitHub no longer lists their gist, because they're on screen.
  /// An open editor may hold a copy `localDrafts` hasn't seen yet, so a refresh keeps by gist.
  private var openGistIDs: Set<String> {
    Set([loadedFile?.selection.gistID, visibleFile?.selection.gistID].compactMap { $0 })
  }

  /// Opens a file in the detail column. A newer open supersedes this one, but keeps any file this
  /// one created.
  func open(_ request: Opening.Request) async {
    guard let account, pendingAccount == nil else {
      openError = String(localized: "Reconnect GitHub to open this gist.")
      return
    }
    let focusesEditor = request.focusesEditor
    if focusesEditor {
      guard !isCreating else { return }
      isCreating = true
    }
    let token = UUID()
    fileRequest = token
    openError = nil
    opening = placeholder(for: request)
    defer {
      if focusesEditor { isCreating = false }
      if token == fileRequest, opening?.failure == nil { opening = nil }
    }
    do {
      var opened = try await file(for: request, account: account)
      if opened.draft == nil {
        let draft = try await sync.draft(for: opened)
        // Recorded, so selecting this file again presents it at once.
        if self.account?.id == account.id { recordLocalDraft(draft) }
        opened.draft = draft
      }
      guard token == fileRequest else { return }
      present(opened)
    } catch is CancellationError {
      if token == fileRequest { state.selectedID = loadedFile?.rowID }
    } catch {
      guard token == fileRequest else { return }
      report(error, operation: "open")
      if case .new = request {
        openError = error.localizedDescription
      } else {
        opening?.failure = error.localizedDescription
        state.selectedID = opening?.rowID
      }
    }
  }

  func openRow(id: String) async {
    await open(request(forRow: id))
  }

  private func file(
    for request: Opening.Request, account: Account
  ) async throws -> File {
    switch request {
    case .gist(let id, let filename, let rowID):
      if let cached = cachedFile(gistID: id, filename: filename, rowID: rowID) { return cached }
      let gist = try await sync.gist(id: id, accountID: account.id)
      let filenames = gist.markdownFilenames
      let selected: String? =
        if let filename {
          filenames.contains(filename) ? filename : nil
        } else if gist.isDailyNote {
          filenames.first { $0 == DailyNote.filename() }
        } else {
          gist.defaultMarkdownFilename
        }
      guard let selected else { throw GitHubClientError.missingFile }
      let text = try await sync.content(gist: gist, filename: selected, accountID: account.id)
      var file = File(
        accountID: account.id, gist: gist, filename: selected, text: text)
      file.libraryRowID = rowID
      return file
    case .draft(let id, let rowID):
      if !localDrafts.contains(where: { $0.id == id }) {
        try await reloadLocalState(accountID: account.id)
      }
      guard let draft = localDrafts.first(where: { $0.id == id }) else { throw DraftError.notFound }
      return localFile(draft, rowID: rowID)
    case .today(let target, let focusesEditor):
      let daily = cachedLibrary?.owned.first(where: \.isDailyNote)
      let day = DailyNote(day: target, cache: cachedLibrary, drafts: localDrafts)
      var file: File
      if let draft = localDrafts.first(where: { $0.id == day.draftID }) {
        file = File(draft: draft, gist: daily)
      } else if let daily,
        let cached = cachedFile(gistID: daily.id, filename: target.filename)
      {
        file = cached
      } else {
        let today = try await sync.today(accountID: account.id, target: target)
        if self.account?.id == account.id { recordLocalDraft(today.draft) }
        file = File(draft: today.draft, gist: today.gist)
      }
      file.editingRequestID = focusesEditor ? UUID() : nil
      file.revealsDetail = focusesEditor
      return file
    case .new:
      let draft = try await sync.createDraft(accountID: account.id)
      if self.account?.id == account.id { recordLocalDraft(draft) }
      var file = File(draft: draft)
      file.editingRequestID = UUID()
      return file
    }
  }

  func showLibrary() {
    fileRequest = UUID()
    opening = nil
    state.selectedID = nil
  }

  func remember(_ selection: FileReference) {
    guard let account else { return }
    lastOpened.save(selection, accountID: account.id)
  }

  /// Reopens the file you last had open. With nothing remembered, nothing opens, because a file
  /// only starts when you ask for it.
  private func restoreLastOpened() async {
    guard loadedFile == nil, state.selectedID == nil, opening == nil, let account,
      pendingAccount == nil
    else { return }
    let saved = lastOpened.selection(accountID: account.id)
    if let draftID = saved?.draftID, localDrafts.contains(where: { $0.id == draftID }) {
      await open(.draft(id: draftID))
    } else if let gistID = saved?.gistID {
      await open(.gist(id: gistID, filename: saved?.filename))
    }
  }

  func reloadPlatformState(accountID: UUID) async throws {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    try await reloadLocalState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
  }

  private func reloadLocalState(
    accountID: UUID, discardAbandonedBlanks: Bool = false
  ) async throws {
    let records = localDraftRecords
    let local = try await sync.localState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { return }
    var removed: Set<UUID> = []
    for draft in local.drafts where discardAbandonedBlanks && draft.isDiscardableBlank {
      guard account?.id == accountID, pendingAccount == nil else { return }
      guard !isCreating, loadedFile?.draft?.id != draft.id, !isDraftSelected(draft.id)
      else { continue }
      if try await discardBlankDraft(draft) { removed.insert(draft.id) }
    }
    guard account?.id == accountID, pendingAccount == nil else { return }
    // A draft created or saved while this read ran is newer than the read, so read again.
    if localDraftRecords != records { return try await reloadLocalState(accountID: accountID) }
    let drafts = local.drafts.filter { $0.accountID == accountID && !removed.contains($0.id) }
    // A refresh drops clean copies of gists GitHub no longer lists, so don't reopen them at launch.
    let vanished = localDrafts.filter { old in !drafts.contains { $0.id == old.id } }
    if let selection = lastOpened.selection(accountID: accountID), vanished.contains(where: {
      $0.id == selection.draftID
        || ($0.gistID != nil && $0.gistID == selection.gistID && $0.filename == selection.filename)
    }) {
      lastOpened.clear(accountID: accountID)
    }
    localDrafts = drafts
    // A deleted file has nothing left to save, so its failure no longer needs attention.
    clearUnsentChange { operation in
      if case .file(let draftID) = operation { !drafts.contains { $0.id == draftID } } else { false }
    }
    cachedLibrary = local.cache
    projectLibrary()
    updateToday()
  }

  private func projectLibrary() {
    guard let account else { return }
    let contents = Self.libraryContents(
      owned: cachedLibrary?.owned ?? [], starred: cachedLibrary?.starred ?? [],
      account: account, drafts: localDrafts, cached: cachedLibrary)
    state.replace(
      gists: contents.gists, tags: contents.tags, dailyNoteCount: contents.dailyNoteCount,
      known: cachedLibrary != nil)
    // A note opened before GitHub's list arrives sits under its draft's row until the gist's row
    // replaces it, so keep it selected under the new row.
    guard let file = loadedFile, !state.gists.contains(where: { $0.id == file.rowID }),
      let rowID = unfilteredRowID(for: file)
    else { return }
    let wasSelected = state.selectedID == file.rowID
    loadedFile?.libraryRowID = rowID
    if wasSelected, opening == nil { state.selectedID = rowID }
  }

  private static func libraryDrafts(
    _ drafts: [Draft], owned: [Gist], accountID: UUID
  ) -> [Draft] {
    drafts.filter { draft in
      guard draft.accountID == accountID else { return false }
      guard let gist = owned.first(where: { $0.id == draft.gistID }),
        gist.isDailyNote, gist.truncated != true, gist.files[draft.filename] == nil
      else { return true }
      return draft.state != .savedToGitHub || draft.attemptedGeneration != nil
    }
  }

  /// The Markdown files a gist shows. A file added on this iPhone shows until it reaches GitHub or
  /// is deleted.
  private static func filenames(of gist: Gist, drafts: [Draft]) -> [String] {
    Set(
      gist.markdownFilenames
        + drafts.filter {
          $0.gistID == gist.id
            && (gist.files[$0.filename] != nil || $0.state != .savedToGitHub)
        }.map(\.filename)
    ).sorted()
  }

  private static func librarySource(draft: Draft?, cached: String?) -> String? {
    if let draft, draft.state != .savedToGitHub || draft.attemptedGeneration != nil {
      return draft.text
    }
    return cached ?? draft?.text
  }


  private func updateToday() {
    let drafts = account.map {
      Self.libraryDrafts(localDrafts, owned: cachedLibrary?.owned ?? [], accountID: $0.id)
    }
    state.today = DailyNote(cache: cachedLibrary, drafts: drafts ?? [])
  }

  private static let recoveryMessage = String(
    localized:
      "This gist was deleted on GitHub. Your unpublished text is kept on this iPhone.")

  func draft(id: UUID, accountID: UUID) async throws -> Draft {
    guard
      let draft = try await sync.localState(accountID: accountID).drafts.first(where: {
        $0.id == id
      })
    else { throw DraftError.notFound }
    return draft
  }

  /// Re-reads a local discard once publication has settled. If the file reached GitHub after the
  /// confirmation, the confirmed deletion removes it there too. That's only its own file, because a
  /// new day can join the daily notes gist an earlier day created, and `deleteFile` takes the gist
  /// with its last file.
  func settledDeletionAction(
    _ action: Change, confirmedWithoutGist: Bool, accountID: UUID
  ) async throws -> Change {
    let draftID: UUID
    switch action {
    case .discardLocalCopy(let id, _): draftID = id
    default: return action
    }
    let draft = try await self.draft(id: draftID, accountID: accountID)
    if confirmedWithoutGist, let gistID = draft.gistID {
      return .deleteFile(gistID: gistID, filename: draft.filename)
    }
    return .discardLocalCopy(draftID: draft.id, generation: draft.generation)
  }

  func isDraftSelected(_ id: UUID) -> Bool {
    state.selectedID != nil && visibleFile?.draft?.id == id
  }

  func discardBlankDraft(_ draft: Draft) async throws -> Bool {
    guard account?.id == draft.accountID, pendingAccount == nil,
      draft.isDiscardableBlank, !isDraftSelected(draft.id)
    else { return false }
    let selection = lastOpened.selection(accountID: draft.accountID)
    guard try await sync.discardBlankDraft(draft) else { return false }
    if selection?.draftID == draft.id,
      lastOpened.selection(accountID: draft.accountID)?.draftID == draft.id
    {
      lastOpened.clear(accountID: draft.accountID)
    }
    guard account?.id == draft.accountID else { return true }
    sessions[draft.id] = nil
    localDrafts.removeAll { $0.id == draft.id }
    state.gists.removeAll { $0.id == draft.id.uuidString }
    if loadedFile?.draft?.id == draft.id, !isDraftSelected(draft.id) {
      loadedFile = nil
    }
    return true
  }

  func uploadImage(_ image: Data, gistID: String, accountID: UUID) async throws -> URL {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    return try await sync.uploadImage(image, gistID: gistID, accountID: accountID)
  }

  func comments(accountID: UUID) async throws -> CommentServices {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    return try await sync.comments(accountID: accountID)
  }

  /// Keeps a gist's comment count current in the library once its conversation loads.
  func recordCommentCount(accountID: UUID, gistID: String, total: Int) {
    guard account?.id == accountID, pendingAccount == nil, !isSigningOut,
      var cache = cachedLibrary, cache.gists.first(where: { $0.id == gistID })?.isDailyNote == false
    else { return }
    let update: (Gist) -> Gist = { $0.id == gistID ? $0.withCommentCount(total) : $0 }
    cache.owned = cache.owned.map(update)
    cache.starred = cache.starred.map(update)
    cache.details = cache.details.mapValues(update)
    cachedLibrary = cache
    projectLibrary()
  }

  /// Runs the last failed write again, reconnecting GitHub first when that's what it needs. Writes
  /// are absolute, so repeating one is safe. A failure that raises attention again isn't rethrown.
  func retryPublish() async throws {
    guard let failure = unsentChange, account?.id == failure.accountID else { return }
    if failure.recovery == .reconnect { await signIn() }
    do {
      switch failure.operation {
      case .change(let change): _ = try await perform(change)
      case .file(let draftID): _ = try await publish(draftID: draftID, accountID: failure.accountID)
      }
    } catch {
      if Self.writeRecovery(for: failure.operation, error) == nil { throw error }
    }
  }

  private func recordUnsentChange(
    _ operation: UnsentChange.Operation, accountID: UUID, error: any Error
  ) {
    guard let recovery = Self.writeRecovery(for: operation, error) else { return }
    unsentChange = UnsentChange(
      operation: operation, accountID: accountID, recovery: recovery)
  }

  private func clearUnsentChange(where matches: (UnsentChange.Operation) -> Bool) {
    guard let unsentChange, matches(unsentChange.operation) else { return }
    self.unsentChange = nil
  }

  /// How a failed GitHub write recovers, or nil when the failure isn't one to raise and retry.
  static func writeRecovery(
    for operation: UnsentChange.Operation, _ error: any Error
  ) -> RemoteReadProblem.Recovery? {
    if (error as? AccountError) == .accountChanged { return nil }
    if case .change(let action) = operation {
      switch action {
      case .preferences, .star, .archive: break
      default: return nil
      }
      if (error as? ChangeError) == .publicationInProgress { return nil }
    }
    return RemoteRead.problem(for: error)?.recovery
  }

  /// Applies a change once the files it touches are saved on this iPhone, holding off typing in
  /// a file it deletes, then brings every open file's details up to date.
  func apply(_ action: Change, accountID: UUID) async throws -> ChangeResult {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isApplying else { throw ChangeError.publicationInProgress }
    isApplying = true
    var locked: [FileSession] = []
    defer {
      for session in locked { session.endDestructiveAction() }
      isApplying = false
    }
    let confirmedWithoutGist: Bool =
      switch action {
      case .discardLocalCopy(let draftID, _): localDrafts.first { $0.id == draftID }?.gistID == nil
      default: false
      }
    do {
      for session in sessions.values {
        let requiresLock: Bool =
          switch action {
          case .delete(let gistID), .deleteFile(let gistID, _):
            session.draft.gistID == gistID
              || localDrafts.contains { $0.id == session.draft.id && $0.gistID == gistID }
          case .discardLocalCopy(let draftID, _): session.draft.id == draftID
          case .signOut: true
          default: false
          }
        guard requiresLock else { continue }
        switch action {
        case .delete, .deleteFile, .discardLocalCopy:
          await session.waitForPublication()
          try Task.checkCancellation()
          guard account?.id == accountID, pendingAccount == nil else {
            throw AccountError.accountChanged
          }
        default: break
        }
        try session.beginDestructiveAction()
        locked.append(session)
      }
      for session in sessions.values {
        guard await session.waitForLocalSave() else { throw EditError.localPersistenceFailed }
      }
      guard account?.id == accountID, pendingAccount == nil else {
        throw AccountError.accountChanged
      }
      let result = try await perform(
        try await settledDeletionAction(
          action, confirmedWithoutGist: confirmedWithoutGist, accountID: accountID))
      switch result {
      case .gist(let gist, _):
        for session in sessions.values where session.draft.gistID == gist.id {
          try await session.refreshMetadata(gist: gist)
        }
      case .account:
        for session in sessions.values { try await session.refreshMetadata() }
      case .draft(let draft, let gist):
        try await sessions[draft.id]?.refreshMetadata(gist: gist)
      case .deletedFile(let gistID, _, let gist):
        for session in sessions.values where session.draft.gistID == gistID {
          try await session.refreshMetadata(gist: gist)
        }
      case .signedOut, .deleted, .discardedDraft, .review, .remoteRead:
        break
      }
      return result
    } catch {
      report(error, operation: "action")
      throw error
    }
  }

  /// Applies a change from a tap. A failure the status control can retry isn't also an alert.
  func run(_ action: Change, accountID: UUID) {
    Task {
      do { _ = try await apply(action, accountID: accountID) } catch {
        guard Self.writeRecovery(for: .change(action), error) == nil else { return }
        openError = error.localizedDescription
      }
    }
  }

  func perform(_ action: Change) async throws -> ChangeResult {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isSigningOut else { throw ChangeError.publicationInProgress }
    if case .signOut = action {
      isSigningOut = true
      libraryRequest = UUID()
    }
    defer {
      if case .signOut = action { isSigningOut = false }
    }
    let result: ChangeResult
    do {
      result = try await sync.perform(action, accountID: account.id)
    } catch {
      if case .signOut = action {
        do {
          if try await sync.cachedAccount() == nil, self.account?.id == account.id {
            reset(to: nil)
          }
        } catch {
          report(error, operation: "confirm-local-sign-out")
        }
      }
      recordUnsentChange(.change(action), accountID: account.id, error: error)
      throw error
    }
    guard self.account?.id == account.id else { throw AccountError.accountChanged }
    // A later successful write means GitHub is reachable again, and every write is absolute, so
    // whatever the failed one changed is no longer shown as changed.
    clearUnsentChange { if case .change = $0 { true } else { false } }
    switch result {
    case .signedOut:
      reset(to: nil)
      return result
    case .account(let updated):
      self.account = updated
      if let cache = cachedLibrary {
        try await sync.cacheLibrary(
          owned: cache.owned, starred: cache.starred, account: updated)
      }
    case .gist(let gist, let starred):
      if var cache = cachedLibrary {
        cache.owned = cache.owned.map { $0.id == gist.id ? gist : $0 }
        cache.starred = cache.starred.map { $0.id == gist.id ? gist : $0 }
        if let starred {
          cache.starred.removeAll { $0.id == gist.id }
          if starred { cache.starred.append(gist) }
        }
        try await sync.cacheLibrary(
          owned: cache.owned, starred: cache.starred, account: account)
      }
    case .draft(let draft, let gist):
      present(File(draft: draft, gist: gist))
    case .deleted(let id):
      let draftIDs = Set(localDrafts.filter { $0.gistID == id }.map(\.id))
      forget(accountID: account.id) {
        $0.gistID == id || $0.draftID.map(draftIDs.contains) == true
      }
      // A refresh that started before the delete would bring the gist back.
      libraryRequest = UUID()
      isRefreshingRemote = false
      if state.loadState == .loading { state.loadState = .ready }
    case .deletedFile(let id, let filename, _):
      forget(accountID: account.id) { $0.gistID == id && $0.filename == filename }
    case .review, .remoteRead:
      break
    case .discardedDraft(let id):
      let discarded = localDrafts.first { $0.id == id }
      forget(accountID: account.id) {
        $0.draftID == id
          || ($0.gistID != nil && $0.gistID == discarded?.gistID
            && $0.filename == discarded?.filename)
      }
      localDrafts.removeAll { $0.id == id }
      projectLibrary()
    }
    try await reloadLocalState(accountID: account.id)
    return result
  }

  /// Closes and forgets the open, opening, failed and remembered file when it no longer exists.
  private func forget(accountID: UUID, where gone: (FileReference) -> Bool) {
    if let loaded = loadedFile, gone(loaded.selection) {
      loadedFile = nil
      state.selectedID = nil
    }
    if let selection = opening?.request.selection, gone(selection) {
      fileRequest = UUID()
      opening = nil
    }
    if let selection = lastOpened.selection(accountID: accountID), gone(selection) {
      lastOpened.clear(accountID: accountID)
    }
    sessions = sessions.filter { !gone($0.value.file.selection) }
  }

  /// Drops everything shown for the current account and switches to `account`, or signs out.
  private func reset(to account: Account?) {
    libraryRequest = UUID()
    fileRequest = UUID()
    self.account = account
    pendingAccount = nil
    loadedFile = nil
    opening = nil
    sessions = [:]
    localDrafts = []
    cachedLibrary = nil
    openError = nil
    remoteRefreshProblem = nil
    unsentChange = nil
    isRefreshingRemote = false
    state.replace(gists: [], known: false)
    state.selectedID = nil
    state.clearFilters()
    if account == nil { state.loadState = .signedOut }
  }

  /// A gist belongs to the signed-in account when its owner is the account's GitHub user, which
  /// holds across login renames.
  func owns(_ gist: Gist) -> Bool {
    guard let id = account?.githubUserID else { return false }
    return gist.owner?.id == id
  }

  /// A file's header and actions, read from its gist, the account's preferences and the drafts on
  /// this iPhone, so it's always current.
  func details(for file: File) -> GistDetails {
    let title =
      file.gist?.displayName
      ?? file.draft.flatMap { $0.description.isEmpty ? nil : $0.description }
      ?? String(localized: "Untitled")
    guard let gist = file.gist, let account, account.id == file.accountID else {
      return GistDetails(
        title: title, files: [.init(id: file.filename, filename: file.filename)],
        selectedFileID: file.filename,
        isDailyNote: file.gist?.isDailyNote ?? (file.draft?.description == DailyNote.gistDescription),
        isAutoSaveEnabled: account?.id == file.accountID
          && account?.preferences.isAutoSaveEnabled == true)
    }
    let files = Self.filenames(of: gist, drafts: localDrafts)
    return GistDetails(
      title: title,
      files: files.map { .init(id: $0, filename: $0) }, selectedFileID: file.filename,
      access: owns(gist) ? .editable : .readOnly,
      isPinned: account.preferences.pinnedGists.contains(gist.id),
      isStarred: cachedLibrary?.starred.contains(where: { $0.id == gist.id }) ?? false,
      isArchived: gist.isArchived, isDailyNote: gist.isDailyNote,
      tags: state.tags.filter {
        account.preferences.gistTags[gist.id]?.contains($0.id) == true
      },
      isAutoSaveEnabled: account.preferences.isAutoSaveEnabled,
      commentCount: gist.isDailyNote ? nil : gist.commentCount,
      shareURL: file.isRecovery || gist.files[file.filename] == nil
        ? nil : try? GistLinks(gist: gist, filename: file.filename).shareURL)
  }

  /// Points the open file at the gist it published to, keeping it selected under its new row.
  private func apply(published saved: Draft, gist: Gist) {
    guard
      loadedFile?.draft?.id == saved.id
        || (loadedFile?.gist?.id == gist.id && loadedFile?.filename == saved.filename)
    else { return }
    let wasSelected = state.selectedID == loadedFile?.rowID
    loadedFile?.gist = gist
    loadedFile?.draft = saved
    if loadedFile?.libraryRowID == saved.id.uuidString { loadedFile?.libraryRowID = nil }
    if wasSelected, opening == nil {
      state.selectedID = loadedFile?.rowID
      remember(FileReference(gistID: gist.id, filename: saved.filename, draftID: saved.id))
    }
  }

  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> Draft
  {
    let saved = try await sync.persist(
      draftID: draftID, accountID: accountID, text: text, generation: generation)
    if account?.id == accountID {
      localDraftRecords += 1
      localDrafts.removeAll { $0.id == saved.id }
      localDrafts.append(saved)
      updateLibraryExcerpt(for: saved)
      updateToday()
    }
    return saved
  }

  /// Publishes each file with unpublished edits, in order, through its editor when it's open. The
  /// first offline result stops the sweep, and the next launch or return to the app retries it.
  func publishUnsyncedEdits() async {
    guard let accountID = account?.id, pendingAccount == nil else { return }
    let ids = localDrafts.filter { $0.accountID == accountID && $0.hasUnpublishedEdits }.map(\.id)
    for id in ids {
      guard !Task.isCancelled else { break }
      let state: PublishState?
      if let session = sessions[id] {
        await session.publish(reason: .background)
        state = session.draft.state
      } else {
        _ = try? await publish(draftID: id, accountID: accountID, reason: .background)
        state = (try? await draft(id: id, accountID: accountID))?.state
      }
      if state == .failed(.network) { break }
    }
    try? await reloadLocalState(accountID: accountID)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason = .manual,
    expectedGeneration: UInt64? = nil,
    shouldPublish: @escaping @Sendable () async -> Bool = { true }
  ) async throws -> Draft {
    guard account?.id == accountID || reason == .manual, pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    let saved: Draft
    do {
      saved = try await sync.publish(
        draftID: draftID, accountID: accountID, reason: reason,
        expectedGeneration: expectedGeneration, shouldPublish: shouldPublish)
    } catch {
      if account?.id == accountID, pendingAccount == nil {
        recordUnsentChange(.file(draftID: draftID), accountID: accountID, error: error)
      }
      throw error
    }
    if saved.state == .savedToGitHub {
      clearUnsentChange { if case .file(draftID) = $0 { true } else { false } }
    }
    if account?.id == accountID {
      libraryRequest = UUID()
      isRefreshingRemote = false
      if state.loadState == .loading { state.loadState = .ready }
      try await reloadLocalState(accountID: accountID)
      if let gist = cachedLibrary?.gists.first(where: { $0.id == saved.gistID }) {
        apply(published: saved, gist: gist)
      }
    }
    return saved
  }

  static func libraryContents(
    owned: [Gist], starred: [Gist], account: Account, drafts: [Draft] = [],
    cached: CachedLibrary? = nil
  )
    -> (gists: [GistItem], tags: [Tag], dailyNoteCount: Int?)
  {
    let ownedIDs = Set(owned.map(\.id))
    let starredIDs = Set(starred.map(\.id))
    var unique: [String: Gist] = [:]
    for gist in owned + starred {
      if let existing = unique[gist.id], existing.updatedAt > gist.updatedAt { continue }
      unique[gist.id] = gist
    }
    let preferences = account.preferences
    let drafts = libraryDrafts(drafts, owned: owned, accountID: account.id)
    var items = unique.values.flatMap { gist -> [GistItem] in
      let gistDrafts = drafts.filter { $0.gistID == gist.id }
      let fileCount = filenames(of: gist, drafts: gistDrafts).count
      let days: [(filename: String, date: Date)?]
      if gist.isDailyNote, ownedIDs.contains(gist.id) {
        days = Set(gist.files.keys).union(gistDrafts.map(\.filename)).compactMap { filename in
          DailyNote.date(filename: filename).map { (filename: filename, date: $0) }
        }.map(Optional.some)
      } else {
        days = [nil]
      }
      return days.map { day in
        var item = GistItem(
          id: day.map { "\(gist.id)/\($0.filename)" } ?? gist.id,
          title: day.map { GistFile.displayName($0.filename) } ?? gist.displayName,
          updatedAt: gist.updatedAt, gistID: gist.id,
          owner: gist.owner?.login, isOwned: ownedIDs.contains(gist.id),
          isSecret: !gist.isPublic, isPinned: preferences.pinnedGists.contains(gist.id),
          isStarred: starredIDs.contains(gist.id), isArchived: gist.isArchived,
          isDailyNote: gist.isDailyNote, tagIDs: Set(preferences.gistTags[gist.id] ?? []),
          filename: day?.filename,
          dailyDate: day?.date,
          fileCount: fileCount,
          commentCount: gist.isDailyNote ? nil : gist.commentCount
        )
        // Only daily rows read file content, for their task progress.
        if gist.isDailyNote {
          let filename = day?.filename ?? DailyNote.filename()
          let inline = gist.files[filename].flatMap {
            $0.truncated == true ? nil : $0.content
          }.map(GistFile.decodeContent)
          updateLibraryContent(&item, text: librarySource(
            draft: gistDrafts.first { $0.filename == filename },
            cached: cached?.content(gist: gist, filename: filename) ?? inline))
        }
        return item
      }
    }
    items += drafts.filter { $0.gistID.map { unique[$0] == nil } ?? true }.compactMap { draft in
      let daily = draft.description == DailyNote.gistDescription
      let day = daily ? DailyNote.date(filename: draft.filename) : nil
      if daily, day == nil { return nil }
      var item = GistItem(
        id: draft.id.uuidString,
        title: daily ? GistFile.displayName(draft.filename)
          : (draft.description.isEmpty ? String(localized: "Untitled") : draft.description),
        updatedAt: draft.updatedAt, isRecovery: draft.gistID != nil,
        isSecret: true, isDailyNote: daily, filename: draft.filename,
        dailyDate: day)
      updateLibraryContent(&item, text: draft.text)
      return item
    }
    let hasIncompleteDaily = unique.values.contains {
      ownedIDs.contains($0.id) && $0.isDailyNote && $0.truncated == true
    }
    return (
      gists: items.sorted {
        if $0.updatedAt != $1.updatedAt {
          return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        return $0.id < $1.id
      },
      tags: preferences.tags.map { tag in
        Tag(id: tag.id, name: tag.name, colorHex: tag.colorHex)
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      dailyNoteCount: hasIncompleteDaily ? nil : items.filter {
        $0.isDailyNote && $0.isOwned && $0.dailyDate != nil
      }.count
    )
  }

  private func report(_ error: any Error, operation: String) {
    logger.error(
      "Library \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)"
    )
  }
}
