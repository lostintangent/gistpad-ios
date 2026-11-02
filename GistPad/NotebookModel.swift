import AuthenticationServices
import Foundation
import GistPadComments
import GistPadEditor
import GistPadInterface
import GistPadSync
import OSLog
import Observation

/// The last GitHub write that failed. A newer failure replaces it, and Retry runs it again.
struct NotebookWriteFailure {
  enum Operation {
    case action(NotebookAction)
    case note(draftID: UUID)
  }

  let operation: Operation
  let accountID: UUID
  let recovery: NotebookRemoteReadProblem.Recovery
}

protocol NotebookProviding: Sendable {
  func cachedAccount() async throws -> Account?
  func connectedAccount() async throws -> Account?
  func signIn() async throws -> Account
  func refreshAccount() async throws -> Account
  func gists(accountID: UUID) async throws -> [Gist]
  func starredGists(accountID: UUID) async throws -> [Gist]
  func gist(id: String, accountID: UUID) async throws -> Gist
  func content(gist: Gist, filename: String, accountID: UUID) async throws -> String
  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot
  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> DraftSnapshot
  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> DraftSnapshot
  func localState(accountID: UUID) async throws -> NotebookLocalState
  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account, keeping: Set<String>)
    async throws
  func createDraft(accountID: UUID) async throws -> DraftSnapshot
  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult
  func uploadPhoto(_ png: Data, gistID: String, accountID: UUID) async throws -> URL
}

extension NotebookProviding {
  func connectedAccount() async throws -> Account? {
    try await cachedAccount()
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account) async throws {
    try await cacheLibrary(owned: owned, starred: starred, account: account, keeping: [])
  }

  func uploadPhoto(_ png: Data, gistID: String, accountID: UUID) async throws -> URL {
    throw CocoaError(.featureUnsupported)
  }
}

actor LiveNotebookProvider: NotebookProviding {
  let accounts: AccountService
  let drafts: DraftStore
  let mutationQueue = NotebookMutationQueue()
  private var clients: [UUID: GitHubClient] = [:]
  private var coordinators: [UUID: SyncCoordinator] = [:]
  private var dailyServices: [UUID: DailyNotesService] = [:]

  init(accounts: AccountService, drafts: DraftStore) {
    self.accounts = accounts
    self.drafts = drafts
  }

  func client(accountID: UUID) async -> GitHubClient {
    if let client = clients[accountID] { return client }
    let client = await accounts.githubClient(accountID: accountID)
    if let existing = clients[accountID] { return existing }
    clients[accountID] = client
    return client
  }

  func cachedAccount() async throws -> Account? {
    try await accounts.cachedAccount()
  }

  func connectedAccount() async throws -> Account? {
    try await accounts.connectedAccount()
  }

  func signIn() async throws -> Account {
    try await accounts.signIn()
  }

  func refreshAccount() async throws -> Account {
    try await accounts.refreshAccount()
  }

  func gists(accountID: UUID) async throws -> [Gist] {
    let client = await client(accountID: accountID)
    return try await client.listGists()
  }

  func starredGists(accountID: UUID) async throws -> [Gist] {
    let client = await client(accountID: accountID)
    return try await client.listStarredGists()
  }

  func gist(id: String, accountID: UUID) async throws -> Gist {
    let client = await client(accountID: accountID)
    let gist = try await client.gist(id: id)
    try await drafts.cacheGist(gist, accountID: accountID)
    return gist
  }

  func content(gist: Gist, filename: String, accountID: UUID) async throws -> String {
    let client = await client(accountID: accountID)
    let text = try await client.content(gist: gist, filename: filename)
    try await drafts.cacheContent(text, gist: gist, filename: filename, accountID: accountID)
    return text
  }

  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    guard let gist = document.gist else { throw GitHubClientError.missingFile }
    guard let account = try await accounts.cachedAccount(), account.id == document.accountID else {
      throw AccountError.accountChanged
    }
    let githubUserID = try await verifiedUserID(accountID: document.accountID)
    return try await drafts.openDraft(
      accountID: document.accountID, githubUserID: githubUserID,
      gistID: gist.id, filename: document.filename,
      description: gist.description ?? "",
      content: document.text, revision: gist.revision)
  }

  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> DraftSnapshot
  {
    try await drafts.persist(id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> DraftSnapshot {
    let coordinator = await coordinator(accountID: accountID)
    return try await mutationQueue.run {
      try await coordinator.publish(
        id: draftID, accountID: accountID, reason: reason,
        expectedGeneration: expectedGeneration, shouldPublish: shouldPublish)
    }
  }

  func localState(accountID: UUID) async throws -> NotebookLocalState {
    let library = try await drafts.cachedLibrary(accountID: accountID)
    let localDrafts = try await drafts.drafts(accountID: accountID)
    return NotebookLocalState(library: library, drafts: localDrafts)
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account, keeping: Set<String>)
    async throws
  {
    try await drafts.cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id,
      keeping: keeping)
  }

  private func verifiedUserID(accountID: UUID) async throws -> Int64 {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    guard let id = account.githubUserID else { throw AccountError.reconnectGitHub }
    return id
  }

  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    let userID = try await verifiedUserID(accountID: accountID)
    return try await drafts.createGistDraft(accountID: accountID, githubUserID: userID)
  }

  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await drafts.discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }

  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    let service: DailyNotesService
    if let existing = dailyServices[accountID] {
      service = existing
    } else {
      let userID = try await verifiedUserID(accountID: accountID)
      let client = await client(accountID: accountID)
      let coordinator = await coordinator(accountID: accountID)
      service =
        dailyServices[accountID]
        ?? DailyNotesService(
          accountID: accountID, githubUserID: userID, client: client,
          store: drafts, coordinator: coordinator)
      dailyServices[accountID] = service
    }
    return try await mutationQueue.run { try await service.stageToday(target: target) }
  }

  private func coordinator(accountID: UUID) async -> SyncCoordinator {
    if let coordinator = coordinators[accountID] { return coordinator }
    let client = await client(accountID: accountID)
    if let existing = coordinators[accountID] { return existing }
    let coordinator = SyncCoordinator(client: client, store: drafts)
    coordinators[accountID] = coordinator
    return coordinator
  }
}

struct NotebookDocument: Equatable, Sendable, Identifiable {
  let accountID: UUID
  var gist: Gist?
  var filename: String
  let text: String
  var draft: DraftSnapshot?
  var isRecovery: Bool
  var libraryRowID: String?
  var editingRequestID: UUID?
  var revealsDetail = true
  var activationID: String { editingRequestID?.uuidString ?? id }
  let id: String

  init(accountID: UUID, gist: Gist, filename: String, text: String) {
    self.accountID = accountID
    self.gist = gist
    self.filename = filename
    self.text = text
    draft = nil
    isRecovery = false
    id = "\(accountID.uuidString)/\(gist.id)/\(filename)"
  }

  init(draft: DraftSnapshot, gist: Gist? = nil, isRecovery: Bool = false) {
    accountID = draft.accountID
    self.gist = gist
    filename = draft.filename
    text = draft.text
    self.draft = draft
    self.isRecovery = isRecovery
    id = "\(draft.accountID.uuidString)/draft/\(draft.id.uuidString)"
  }

  var selection: NotebookSelection {
    NotebookSelection(gistID: gist?.id ?? draft?.gistID, filename: filename, draftID: draft?.id)
  }

  var rowID: String {
    if let libraryRowID { return libraryRowID }
    if let gist, gist.isDailyNote {
      return "\(gist.id)/\(filename)"
    }
    return gist?.id ?? draft?.id.uuidString ?? id
  }

  func refersToSameFile(as other: NotebookDocument) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if let draftID = draft?.id, draftID == other.draft?.id { return true }
    if let gistID = selection.gistID { return gistID == other.selection.gistID }
    return false
  }
}

/// A note on its way to the detail column, and why it couldn't open if it failed.
struct NotebookOpening: Equatable {
  enum Request: Equatable {
    case gist(id: String, filename: String? = nil, rowID: String? = nil)
    case draft(id: UUID, rowID: String? = nil)
    case today(DailyNoteTarget = DailyNoteTarget(), focusesEditor: Bool = true)
    case new

    /// Creating a note or starting the day puts the caret in it.
    var focusesEditor: Bool {
      switch self {
      case .new: true
      case .today(_, let focusesEditor): focusesEditor
      case .gist, .draft: false
      }
    }

    /// The saved note this opens, so deleting that note stops the opening.
    fileprivate var selection: NotebookSelection? {
      switch self {
      case .gist(let id, let filename, _): .init(gistID: id, filename: filename ?? "", draftID: nil)
      case .draft(let id, _): .init(gistID: nil, filename: "", draftID: id)
      case .today, .new: nil
      }
    }
  }

  let request: Request
  let rowID: String
  let title: String
  var failure: String?

  var filename: String? {
    switch request {
    case .gist(_, let filename, _): filename
    case .today(let target, _): target.filename
    case .draft, .new: nil
    }
  }
}

@MainActor @Observable
final class NotebookModel {
  let library = LibraryModel()
  private(set) var account: Account?
  private(set) var pendingAccount: Account?
  private(set) var loadedDocument: NotebookDocument?
  private(set) var isSigningIn = false
  private(set) var isSigningOut = false
  private(set) var isStarting = false
  /// The note opening in the detail column, until it's presented or fails.
  private(set) var opening: NotebookOpening?
  private(set) var localDrafts: [DraftSnapshot] = []
  /// Counts drafts recorded in memory, so a local read that started earlier knows it's stale.
  private var localDraftRecords = 0
  private(set) var cachedLibrary: CachedLibrarySnapshot?
  private(set) var isCreating = false
  /// The one message the app shows in an alert, such as a failed open or action.
  var documentError: String?
  var isShowingError: Bool {
    get { documentError != nil }
    set { if !newValue { documentError = nil } }
  }
  private(set) var remoteRefreshProblem: NotebookRemoteReadProblem?
  private(set) var isRefreshingRemote = false
  private(set) var writeFailure: NotebookWriteFailure?
  /// The notes opened this session, by draft. Returning to one keeps its caret, scroll and undo.
  private(set) var files: [UUID: NotebookSessionController] = [:]
  /// Autosave runs only while the app is in the foreground.
  var isForeground = false
  private(set) var isApplying = false

  @ObservationIgnored private let provider: any NotebookProviding
  @ObservationIgnored private let selections: NotebookSelectionStore
  @ObservationIgnored private var libraryRequest = UUID()
  @ObservationIgnored private var documentRequest = UUID()
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Notebook")

  init(
    provider: any NotebookProviding, selections: NotebookSelectionStore = NotebookSelectionStore()
  ) {
    self.provider = provider
    self.selections = selections
  }

  var writeAttentionStatus: GitHubStatusState? {
    guard let writeFailure, account?.id == writeFailure.accountID else { return nil }
    // Pins, tags and settings are saved to the GistPad account, not GitHub.
    let (message, detail): (String, String?) =
      switch (writeFailure.operation, writeFailure.recovery) {
      case (_, .reconnect): (AccountError.reconnectGitHub.localizedDescription, nil)
      case (.note, _):
        (
          String(localized: "This file didn't reach GitHub."),
          String(localized: "Your changes are saved on this iPhone.")
        )
      case (.action(.preference), _), (.action(.saveTags), _):
        (String(localized: "This change wasn't saved."), nil)
      case (.action, _): (String(localized: "This change didn't reach GitHub."), nil)
      }
    return NotebookRemoteReadProblem(message: message, recovery: writeFailure.recovery)
      .status(heading: String(localized: "Couldn't sync"), detail: detail)
  }

  // A failed GitHub-backed write outranks read problems, because it means local changes didn't reach GitHub.
  var remoteRefreshStatus: GitHubStatusState {
    if let status = writeAttentionStatus { return status }
    if let problem = remoteRefreshProblem, cachedLibrary != nil || !localDrafts.isEmpty {
      return problem.status(
        heading: String(localized: "Couldn't update your gists"),
        detail: String(localized: "Your notes on this iPhone are unchanged."))
    }
    return isRefreshingRemote
      ? .checking(operation: String(localized: "Checking GitHub for changes")) : .idle
  }

  var presentedDocument: NotebookDocument? {
    if let opening { return opening.failure == nil ? cachedDocument(rowID: opening.rowID) : nil }
    guard let selected = library.selectedNoteID else { return loadedDocument }
    if loadedDocument?.rowID == selected { return loadedDocument }
    return cachedDocument(rowID: selected)
  }

  /// The editor for the note in the detail column.
  var activeFile: NotebookSessionController? {
    guard let document = presentedDocument else { return nil }
    return files.values.first { $0.document.refersToSameFile(as: document) }
  }

  var openingTitle: String? {
    if let opening { return opening.title }
    guard let selected = library.selectedNoteID, selected != loadedDocument?.rowID else {
      return nil
    }
    return placeholder(for: request(forRow: selected)).title
  }

  var isTodaySelected: Bool {
    if let opening { return if case .today = opening.request { true } else { false } }
    guard let document = presentedDocument,
      document.filename == GistConventions.todayFilename()
    else { return false }
    return document.gist?.isDailyNote == true
      || document.draft?.description == GistConventions.dailyNotesDescription
  }

  @discardableResult
  func beginOpeningRow(id: String) -> Bool {
    guard account != nil, pendingAccount == nil else {
      documentError = String(localized: "Reconnect GitHub before opening this note.")
      return false
    }
    documentRequest = UUID()
    documentError = nil
    if let document = cachedDocument(rowID: id), document.draft != nil {
      present(document)
      return true
    }
    opening = placeholder(for: request(forRow: id))
    library.selectedNoteID = id
    return false
  }

  /// Opens a library row, at once when its note is already on this iPhone.
  func select(rowID id: String) {
    guard !beginOpeningRow(id: id), opening?.rowID == id else { return }
    let request = documentRequest
    Task {
      guard request == documentRequest else { return }
      await openRow(id: id)
    }
  }

  func libraryDeletionTarget(for rowID: String) -> NotebookDeletionTarget? {
    guard let account, pendingAccount == nil else { return nil }
    let target = rowSelection(for: rowID)
    let draftID = target?.draftID
    let draft = draftID.flatMap { id in localDrafts.first { $0.id == id } }
    if let draft,
      draft.gistID.flatMap({ gistID in cachedLibrary?.gists.contains(where: { $0.id == gistID }) }) != true
    {
      return .init(
        id: draft.id.uuidString, accountID: account.id,
        title: draft.description.isEmpty ? String(localized: "Untitled") : draft.description,
        localDraft: draft)
    }
    let gistID = target?.gistID ?? draft?.gistID ?? rowID
    guard let gist = cachedLibrary?.owned.first(where: { $0.id == gistID }) else { return nil }
    if gist.isDailyNote, let filename = target?.filename {
      return .init(
        id: gist.id, accountID: account.id,
        title: GistConventions.fileDisplayName(filename), filename: filename)
    }
    return .init(id: gist.id, accountID: account.id, title: gist.displayName)
  }

  func gistID(forRow rowID: String) -> String? {
    if cachedLibrary?.gists.contains(where: { $0.id == rowID }) == true { return rowID }
    return library.snapshot.notes.first { $0.id == rowID && $0.isDailyNote }?.gistID
  }

  private func rowSelection(for rowID: String) -> NotebookSelection? {
    if let id = UUID(uuidString: rowID), let draft = localDrafts.first(where: { $0.id == id }) {
      return .init(gistID: draft.gistID, filename: draft.filename, draftID: id)
    }
    if let row = library.snapshot.notes.first(where: { $0.id == rowID }),
      let gistID = row.gistID, let filename = row.filename
    {
      return .init(gistID: gistID, filename: filename, draftID: nil)
    }
    return nil
  }

  func cachedDocument(rowID: String) -> NotebookDocument? {
    if let target = rowSelection(for: rowID) {
      if let draftID = target.draftID, let draft = localDrafts.first(where: { $0.id == draftID }) {
        return localDocument(draft, rowID: rowID)
      }
      if let gistID = target.gistID {
        return cachedDocument(gistID: gistID, filename: target.filename, rowID: rowID)
      }
      return nil
    }
    return cachedDocument(gistID: rowID, rowID: rowID)
  }

  private func cachedDocument(
    gistID: String, filename: String? = nil, rowID: String? = nil
  ) -> NotebookDocument? {
    guard let account, pendingAccount == nil else { return nil }
    let gist = cachedLibrary?.gists.first { $0.id == gistID }
    let selectedFilename: String?
    if let filename {
      selectedFilename = filename
    } else if let gist {
      guard gist.truncated != true || gist.isDailyNote else { return nil }
      selectedFilename = gist.isDailyNote ? GistConventions.todayFilename() : gist.defaultMarkdownFilename
    } else {
      let candidates = localDrafts.filter { $0.gistID == gistID }
      selectedFilename = candidates.count == 1 ? candidates.first?.filename : nil
    }
    guard let selectedFilename, selectedFilename.hasSuffix(".md") else { return nil }
    if let draft = localDrafts.first(where: {
      $0.accountID == account.id && $0.gistID == gistID && $0.filename == selectedFilename
    }) {
      return localDocument(draft, rowID: rowID)
    }
    guard let gist, let text = cachedLibrary?.content(gist: gist, filename: selectedFilename) else {
      return nil
    }
    var document = NotebookDocument(
      accountID: account.id, gist: gist, filename: selectedFilename, text: text)
    document.libraryRowID = rowID
    return document
  }

  private func localDocument(_ draft: DraftSnapshot, rowID: String?) -> NotebookDocument {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
    var document = NotebookDocument(
      draft: draft, gist: gist,
      isRecovery: draft.gistID != nil && gist == nil)
    document.libraryRowID = rowID
    return document
  }

  private func request(forRow id: String) -> NotebookOpening.Request {
    let target = rowSelection(for: id)
    // A note that never reached GitHub only exists on this iPhone.
    if let draftID = target?.draftID,
      target?.gistID == nil
        || localDrafts.contains(where: { $0.id == draftID && $0.baseContent == nil })
    {
      return .draft(id: draftID, rowID: id)
    }
    return .gist(id: target?.gistID ?? id, filename: target?.filename, rowID: id)
  }

  private func placeholder(for request: NotebookOpening.Request) -> NotebookOpening {
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
      title: library.snapshot.notes.first { $0.id == rowID }?.title ?? title
        ?? String(localized: "Note"))
  }

  private func present(_ document: NotebookDocument) {
    var document = document
    document.libraryRowID = unfilteredRowID(for: document)
    opening = nil
    loadedDocument = document
    library.selectedNoteID = document.rowID
    if document.isRecovery { documentError = Self.recoveryMessage }
    remember(document.selection)
    guard let draft = document.draft else { return }
    if let file = files.values.first(where: { $0.document.refersToSameFile(as: document) }) {
      file.adoptPresentation(document)
    } else {
      files[draft.id] = NotebookSessionController(document: document, draft: draft, notebook: self)
    }
  }

  private func unfilteredRowID(for document: NotebookDocument) -> String? {
    library.snapshot.notes.first {
      $0.id == document.draft?.id.uuidString
        || ($0.gistID != nil && $0.gistID == document.selection.gistID
          && ($0.filename == nil || $0.filename == document.filename))
    }?.id
  }

  private func recordLocalDraft(_ draft: DraftSnapshot) {
    localDraftRecords += 1
    localDrafts.removeAll { $0.id == draft.id }
    localDrafts.append(draft)
    projectLibrary()
    updateToday()
  }

  private func updateLibraryExcerpt(for draft: DraftSnapshot) {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
    let isDaily = gist?.isDailyNote == true
      || draft.description == GistConventions.dailyNotesDescription
    if isDaily, DailyNotesIndex.parseDateFilename(draft.filename) == nil { return }
    if let gist, !gist.isDailyNote, draft.filename != gist.defaultMarkdownFilename { return }
    let rowID =
      if let gist, gist.isDailyNote, owns(gist) {
        "\(gist.id)/\(draft.filename)"
      } else { gist?.id ?? draft.id.uuidString }
    guard let index = library.snapshot.notes.firstIndex(where: { $0.id == rowID }) else {
      projectLibrary()
      return
    }
    if library.snapshot.notes[index].gistID == nil {
      library.snapshot.notes[index].updatedAt = draft.updatedAt
    }
    Self.updateLibraryContent(&library.snapshot.notes[index], text: draft.text)
  }

  private static func updateLibraryContent(_ note: inout LibraryNote, text: String?) {
    if note.isDailyNote {
      note.progress = text.map(TaskProgress.init(markdown:))
      note.isOverdue = note.dailyDate.map {
        $0 < Calendar.current.startOfDay(for: .now) && (note.progress?.remaining ?? 0) > 0
      } ?? false
    }
  }

  func start() async {
    guard !isStarting, !isSigningOut else { return }
    isStarting = true
    defer { isStarting = false }
    let request = UUID()
    libraryRequest = request
    library.loadState = .loading
    do {
      let restored = try await provider.connectedAccount()
      guard request == libraryRequest else { return }
      guard let restored else {
        library.loadState = .signedOut
        return
      }
      account = restored
      try await reloadLocalState(accountID: restored.id, discardAbandonedBlanks: true)
      await refresh()
      await restoreSelectionIfNeeded()
    } catch is CancellationError {
      if request == libraryRequest {
        library.loadState = account == nil ? .signedOut : .ready
      }
    } catch {
      guard request == libraryRequest else { return }
      report(error, operation: "restore")
      library.loadState = .failed(message: error.localizedDescription)
    }
  }

  func signIn() async {
    guard !isSigningIn, !isSigningOut else { return }
    isSigningIn = true
    let previousState = library.loadState
    defer { isSigningIn = false }
    do {
      let signedIn = try await provider.signIn()
      libraryRequest = UUID()
      if let account, account.id != signedIn.id {
        pendingAccount = signedIn
        library.loadState = .reconnectRequired(
          message: String(
            localized:
              "A different GitHub account signed in. Keep the current notebook or switch to it."
          ))
        return
      }
      account = signedIn
      pendingAccount = nil
      try await reloadLocalState(accountID: signedIn.id, discardAbandonedBlanks: true)
      await refresh()
      await restoreSelectionIfNeeded()
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      library.loadState = previousState
    } catch is CancellationError {
      library.loadState = previousState
    } catch {
      libraryRequest = UUID()
      report(error, operation: "sign-in")
      library.loadState = .reconnectRequired(message: error.localizedDescription)
    }
  }

  /// Switches to the account that just signed in, once every open note is saved on this iPhone.
  func acceptPendingAccount() async throws {
    guard let pendingAccount else { return }
    for file in files.values {
      guard !file.isPublishing, !file.isApplyingDurableEdit else {
        throw NotebookActionError.publicationInProgress
      }
      guard file.session.isSettled else { throw SourceEdit.MutationError.compositionActive }
      guard await file.waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
    }
    guard self.pendingAccount == pendingAccount else { return }
    reset(to: pendingAccount)
    do {
      try await reloadLocalState(accountID: pendingAccount.id, discardAbandonedBlanks: true)
    } catch {
      report(error, operation: "reload-local")
      documentError = error.localizedDescription
    }
    await refresh()
    await restoreSelectionIfNeeded()
  }

  func keepCurrentNotebook() {
    pendingAccount = nil
    library.loadState = .reconnectRequired(
      message: String(
        localized:
          "Your current notebook and drafts are kept. Reconnect its original GitHub account before publishing."
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
      return try await provider.refreshAccount()
    } catch {
      if error is CancellationError || (error as? AccountError) == .reconnectGitHub { throw error }
      guard let connected = try await provider.connectedAccount() else { throw error }
      return connected
    }
  }

  func refresh() async {
    guard pendingAccount == nil, !isSigningOut else { return }
    guard let account else {
      await start()
      return
    }
    let request = UUID()
    libraryRequest = request
    let previousState: LibraryLoadState = library.loadState == .loading ? .ready : library.loadState
    isRefreshingRemote = true
    defer {
      if request == libraryRequest { isRefreshingRemote = false }
    }
    library.loadState = .loading
    do {
      let refreshed = try await refreshedAccount()
      guard refreshed.id == account.id else { throw AccountError.accountChanged }
      async let ownedGists = provider.gists(accountID: account.id)
      async let starredGists = provider.starredGists(accountID: account.id)
      let (owned, starred) = try await (ownedGists, starredGists)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      try await provider.cacheLibrary(
        owned: owned, starred: starred, account: refreshed, keeping: openGistIDs)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      self.account = refreshed
      library.loadState = .ready
      try await reloadLocalState(accountID: account.id)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      remoteRefreshProblem = nil
    } catch {
      guard request == libraryRequest else { return }
      guard let problem = NotebookRemoteRead.problem(for: error) else {
        library.loadState = previousState
        return
      }
      report(error, operation: "refresh")
      remoteRefreshProblem = problem
      library.loadState =
        problem.recovery == .reconnect
        ? .reconnectRequired(message: error.localizedDescription)
        : .failed(message: error.localizedDescription)
    }
  }

  /// Drafts a refresh keeps even when GitHub no longer lists their gist, because they're on screen.
  /// An open editor may hold a copy `localDrafts` hasn't seen yet, so a refresh keeps by gist.
  private var openGistIDs: Set<String> {
    Set([loadedDocument?.selection.gistID, presentedDocument?.selection.gistID].compactMap { $0 })
  }

  /// Opens a note in the detail column. A newer open supersedes this one, but keeps any note this
  /// one created.
  func open(_ request: NotebookOpening.Request) async {
    guard let account, pendingAccount == nil else {
      documentError = String(localized: "Reconnect GitHub before opening this note.")
      return
    }
    let focusesEditor = request.focusesEditor
    if focusesEditor {
      guard !isCreating else { return }
      isCreating = true
    }
    let token = UUID()
    documentRequest = token
    documentError = nil
    opening = placeholder(for: request)
    defer {
      if focusesEditor { isCreating = false }
      if token == documentRequest, opening?.failure == nil { opening = nil }
    }
    do {
      var opened = try await document(for: request, account: account)
      if opened.draft == nil { opened.draft = try await provider.openDraft(for: opened) }
      guard token == documentRequest else { return }
      present(opened)
    } catch is CancellationError {
      if token == documentRequest { library.selectedNoteID = loadedDocument?.rowID }
    } catch {
      guard token == documentRequest else { return }
      report(error, operation: "open")
      if case .new = request {
        documentError = error.localizedDescription
      } else {
        opening?.failure = error.localizedDescription
        library.selectedNoteID = opening?.rowID
      }
    }
  }

  func openRow(id: String) async {
    await open(request(forRow: id))
  }

  private func document(
    for request: NotebookOpening.Request, account: Account
  ) async throws -> NotebookDocument {
    switch request {
    case .gist(let id, let filename, let rowID):
      if let cached = cachedDocument(gistID: id, filename: filename, rowID: rowID) { return cached }
      let gist = try await provider.gist(id: id, accountID: account.id)
      let filenames = gist.markdownFilenames
      let selected: String? =
        if let filename {
          filenames.contains(filename) ? filename : nil
        } else if gist.isDailyNote {
          filenames.first { $0 == GistConventions.todayFilename() }
        } else {
          gist.defaultMarkdownFilename
        }
      guard let selected else { throw GitHubClientError.missingFile }
      let text = try await provider.content(gist: gist, filename: selected, accountID: account.id)
      var document = NotebookDocument(
        accountID: account.id, gist: gist, filename: selected, text: text)
      document.libraryRowID = rowID
      return document
    case .draft(let id, let rowID):
      if !localDrafts.contains(where: { $0.id == id }) {
        try await reloadLocalState(accountID: account.id)
      }
      guard let draft = localDrafts.first(where: { $0.id == id }) else { throw DraftError.notFound }
      return localDocument(draft, rowID: rowID)
    case .today(let target, let focusesEditor):
      let daily = cachedLibrary?.owned.first(where: \.isDailyNote)
      let day = DailyNote(day: target, cache: cachedLibrary, drafts: localDrafts)
      var document: NotebookDocument
      if let draft = localDrafts.first(where: { $0.id == day.draftID }) {
        document = NotebookDocument(draft: draft, gist: daily)
      } else if let daily,
        let cached = cachedDocument(gistID: daily.id, filename: target.filename)
      {
        document = cached
      } else {
        let today = try await provider.today(accountID: account.id, target: target)
        if self.account?.id == account.id { recordLocalDraft(today.draft) }
        document = NotebookDocument(draft: today.draft, gist: today.gist)
      }
      document.editingRequestID = focusesEditor ? UUID() : nil
      document.revealsDetail = focusesEditor
      return document
    case .new:
      let draft = try await provider.createDraft(accountID: account.id)
      if self.account?.id == account.id { recordLocalDraft(draft) }
      var document = NotebookDocument(draft: draft)
      document.editingRequestID = UUID()
      return document
    }
  }

  func showLibrary() {
    documentRequest = UUID()
    opening = nil
    library.selectedNoteID = nil
  }

  func remember(_ selection: NotebookSelection) {
    guard let account else { return }
    selections.save(selection, accountID: account.id)
  }

  private func restoreSelectionIfNeeded() async {
    guard loadedDocument == nil, library.selectedNoteID == nil, opening == nil, let account,
      pendingAccount == nil
    else { return }
    let saved = selections.selection(accountID: account.id)
    if let draftID = saved?.draftID, localDrafts.contains(where: { $0.id == draftID }) {
      await open(.draft(id: draftID))
      return
    }
    if let gistID = saved?.gistID {
      await open(.gist(id: gistID, filename: saved?.filename))
      if loadedDocument != nil { return }
    }
    guard loadedDocument == nil, library.selectedNoteID == nil else { return }
    await open(.today(focusesEditor: false))
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
    let local = try await provider.localState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { return }
    var removed: Set<UUID> = []
    for draft in local.drafts where discardAbandonedBlanks && draft.isDiscardableBlank {
      guard account?.id == accountID, pendingAccount == nil else { return }
      guard !isCreating, loadedDocument?.draft?.id != draft.id, !isDraftSelected(draft.id)
      else { continue }
      if try await discardBlankDraft(draft) { removed.insert(draft.id) }
    }
    guard account?.id == accountID, pendingAccount == nil else { return }
    // A draft created or saved while this read ran is newer than the read, so read again.
    if localDraftRecords != records { return try await reloadLocalState(accountID: accountID) }
    let drafts = local.drafts.filter { $0.accountID == accountID && !removed.contains($0.id) }
    // A refresh drops clean copies of gists GitHub no longer lists, so don't reopen them at launch.
    let vanished = localDrafts.filter { old in !drafts.contains { $0.id == old.id } }
    if let selection = selections.selection(accountID: accountID), vanished.contains(where: {
      $0.id == selection.draftID
        || ($0.gistID != nil && $0.gistID == selection.gistID && $0.filename == selection.filename)
    }) {
      selections.clear(accountID: accountID)
    }
    localDrafts = drafts
    // A deleted note has nothing left to save, so its failure no longer needs attention.
    clearWriteFailure { operation in
      if case .note(let draftID) = operation { !drafts.contains { $0.id == draftID } } else { false }
    }
    cachedLibrary = local.library
    projectLibrary()
    updateToday()
  }

  private func projectLibrary() {
    guard let account else { return }
    let snapshot = Self.librarySnapshot(
      owned: cachedLibrary?.owned ?? [], starred: cachedLibrary?.starred ?? [],
      account: account, drafts: localDrafts, cached: cachedLibrary)
    if let cachedLibrary {
      library.replaceSnapshot(snapshot)
    } else {
      library.replaceSnapshot(nil)
      library.snapshot = snapshot
      library.snapshot.dailyNoteCount = nil
    }
  }

  private static func libraryDrafts(
    _ drafts: [DraftSnapshot], owned: [Gist], accountID: UUID
  ) -> [DraftSnapshot] {
    drafts.filter { draft in
      guard draft.accountID == accountID else { return false }
      guard let gist = owned.first(where: { $0.id == draft.gistID }),
        gist.isDailyNote, gist.truncated != true, gist.files[draft.filename] == nil
      else { return true }
      return draft.state != .savedToGitHub || draft.attemptedGeneration != nil
    }
  }

  private static func librarySource(draft: DraftSnapshot?, cached: String?) -> String? {
    if let draft, draft.state != .savedToGitHub || draft.attemptedGeneration != nil {
      return draft.text
    }
    return cached ?? draft?.text
  }


  private func updateToday() {
    let drafts = account.map {
      Self.libraryDrafts(localDrafts, owned: cachedLibrary?.owned ?? [], accountID: $0.id)
    }
    library.today = DailyNote(cache: cachedLibrary, drafts: drafts ?? [])
  }

  private static let recoveryMessage = String(
    localized:
      "The GitHub note is unavailable. Your local draft is safe and can still be read or exported.")

  func draftSnapshot(id: UUID, accountID: UUID) async throws -> DraftSnapshot {
    guard
      let draft = try await provider.localState(accountID: accountID).drafts.first(where: {
        $0.id == id
      })
    else { throw DraftError.notFound }
    return draft
  }

  /// Re-reads a local discard once publication has settled. If the note reached GitHub after the
  /// confirmation, the confirmed deletion becomes a GitHub deletion of the gist it created.
  func settledDeletionAction(
    _ action: NotebookAction, confirmedWithoutGist: Bool, accountID: UUID
  ) async throws -> NotebookAction {
    let draftID: UUID
    switch action {
    case .discardLocalCopy(let id, _): draftID = id
    default: return action
    }
    let draft = try await draftSnapshot(id: draftID, accountID: accountID)
    if confirmedWithoutGist, let gistID = draft.gistID {
      return .delete(gistID: gistID)
    }
    return .discardLocalCopy(draftID: draft.id, generation: draft.generation)
  }

  func isDraftSelected(_ id: UUID) -> Bool {
    library.selectedNoteID != nil && presentedDocument?.draft?.id == id
  }

  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    guard account?.id == draft.accountID, pendingAccount == nil,
      draft.isDiscardableBlank, !isDraftSelected(draft.id)
    else { return false }
    let selection = selections.selection(accountID: draft.accountID)
    guard try await provider.discardBlankDraft(draft) else { return false }
    if selection?.draftID == draft.id,
      selections.selection(accountID: draft.accountID)?.draftID == draft.id
    {
      selections.clear(accountID: draft.accountID)
    }
    guard account?.id == draft.accountID else { return true }
    files[draft.id] = nil
    localDrafts.removeAll { $0.id == draft.id }
    library.snapshot.notes.removeAll { $0.id == draft.id.uuidString }
    if loadedDocument?.draft?.id == draft.id, !isDraftSelected(draft.id) {
      loadedDocument = nil
    }
    if !isStarting, !isSigningIn, !isCreating { await restoreSelectionIfNeeded() }
    return true
  }

  func uploadPhoto(_ png: Data, gistID: String, accountID: UUID) async throws -> URL {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    return try await provider.uploadPhoto(png, gistID: gistID, accountID: accountID)
  }

  func commentServices(accountID: UUID) async throws -> NotebookCommentServices {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    guard let provider = provider as? any NotebookCommentProviding else {
      throw NotebookCommentError.unavailable
    }
    return try await provider.commentServices(accountID: accountID)
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
  func retryWrite() async throws {
    guard let failure = writeFailure, account?.id == failure.accountID else { return }
    if failure.recovery == .reconnect { await signIn() }
    do {
      switch failure.operation {
      case .action(let action): _ = try await perform(action)
      case .note(let draftID): _ = try await publish(draftID: draftID, accountID: failure.accountID)
      }
    } catch {
      if Self.writeRecovery(for: failure.operation, error) == nil { throw error }
    }
  }

  private func recordWriteFailure(
    _ operation: NotebookWriteFailure.Operation, accountID: UUID, error: any Error
  ) {
    guard let recovery = Self.writeRecovery(for: operation, error) else { return }
    writeFailure = NotebookWriteFailure(
      operation: operation, accountID: accountID, recovery: recovery)
  }

  private func clearWriteFailure(where matches: (NotebookWriteFailure.Operation) -> Bool) {
    guard let writeFailure, matches(writeFailure.operation) else { return }
    self.writeFailure = nil
  }

  /// How a failed GitHub write recovers, or nil when the failure isn't one to raise and retry.
  static func writeRecovery(
    for operation: NotebookWriteFailure.Operation, _ error: any Error
  ) -> NotebookRemoteReadProblem.Recovery? {
    if (error as? AccountError) == .accountChanged { return nil }
    if case .action(let action) = operation {
      switch action {
      case .preference, .saveTags, .star, .archive: break
      default: return nil
      }
      if (error as? NotebookActionError) == .publicationInProgress { return nil }
    }
    return NotebookRemoteRead.problem(for: error)?.recovery
  }

  /// Applies an action once the notes it touches are saved on this iPhone, holding off typing in
  /// a note it deletes, then brings every open note's details up to date.
  func apply(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isApplying else { throw NotebookActionError.publicationInProgress }
    isApplying = true
    var locked: [NotebookSessionController] = []
    defer {
      for file in locked { file.endDestructiveAction() }
      isApplying = false
    }
    let confirmedWithoutGist: Bool =
      switch action {
      case .discardLocalCopy(let draftID, _): localDrafts.first { $0.id == draftID }?.gistID == nil
      default: false
      }
    do {
      for file in files.values {
        let requiresLock: Bool =
          switch action {
          case .delete(let gistID), .deleteFile(let gistID, _):
            file.draft.gistID == gistID
              || localDrafts.contains { $0.id == file.draft.id && $0.gistID == gistID }
          case .discardLocalCopy(let draftID, _): file.draft.id == draftID
          case .signOut: true
          default: false
          }
        guard requiresLock else { continue }
        switch action {
        case .delete, .deleteFile, .discardLocalCopy:
          await file.waitForPublication()
          try Task.checkCancellation()
          guard account?.id == accountID, pendingAccount == nil else {
            throw AccountError.accountChanged
          }
        default: break
        }
        try file.beginDestructiveAction()
        locked.append(file)
      }
      for file in files.values {
        guard await file.waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
      }
      guard account?.id == accountID, pendingAccount == nil else {
        throw AccountError.accountChanged
      }
      let result = try await perform(
        try await settledDeletionAction(
          action, confirmedWithoutGist: confirmedWithoutGist, accountID: accountID))
      switch result {
      case .gist(let gist, _):
        for file in files.values where file.draft.gistID == gist.id {
          try await file.refreshMetadata(gist: gist)
        }
      case .account:
        for file in files.values { try await file.refreshMetadata() }
      case .draft(let draft, let gist):
        try await files[draft.id]?.refreshMetadata(gist: gist)
      case .deletedFile(let gistID, _, let gist):
        for file in files.values where file.draft.gistID == gistID {
          try await file.refreshMetadata(gist: gist)
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

  /// Applies an action from a tap. A failure the status control can retry isn't also an alert.
  func run(_ action: NotebookAction, accountID: UUID) {
    Task {
      do { _ = try await apply(action, accountID: accountID) } catch {
        guard Self.writeRecovery(for: .action(action), error) == nil else { return }
        documentError = error.localizedDescription
      }
    }
  }

  func perform(_ action: NotebookAction) async throws -> NotebookActionResult {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    guard !isSigningOut else { throw NotebookActionError.publicationInProgress }
    if case .signOut = action {
      isSigningOut = true
      libraryRequest = UUID()
    }
    defer {
      if case .signOut = action { isSigningOut = false }
    }
    let result: NotebookActionResult
    do {
      result = try await provider.perform(action, accountID: account.id)
    } catch {
      if case .signOut = action {
        do {
          if try await provider.cachedAccount() == nil, self.account?.id == account.id {
            reset(to: nil)
          }
        } catch {
          report(error, operation: "confirm-local-sign-out")
        }
      }
      recordWriteFailure(.action(action), accountID: account.id, error: error)
      throw error
    }
    guard self.account?.id == account.id else { throw AccountError.accountChanged }
    // A later successful write means GitHub is reachable again, and every write is absolute, so
    // whatever the failed one changed is no longer shown as changed.
    clearWriteFailure { if case .action = $0 { true } else { false } }
    switch result {
    case .signedOut:
      reset(to: nil)
      return result
    case .account(let updated):
      self.account = updated
      if let cache = cachedLibrary {
        try await provider.cacheLibrary(
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
        try await provider.cacheLibrary(
          owned: cache.owned, starred: cache.starred, account: account)
      }
    case .draft(let draft, let gist):
      present(NotebookDocument(draft: draft, gist: gist))
    case .deleted(let id):
      let draftIDs = Set(localDrafts.filter { $0.gistID == id }.map(\.id))
      forget(accountID: account.id) {
        $0.gistID == id || $0.draftID.map(draftIDs.contains) == true
      }
      // A refresh that started before the delete would bring the gist back.
      libraryRequest = UUID()
      isRefreshingRemote = false
      if library.loadState == .loading { library.loadState = .ready }
      if let cache = cachedLibrary {
        try await provider.cacheLibrary(
          owned: cache.owned.filter { $0.id != id }, starred: cache.starred.filter { $0.id != id },
          account: account)
      }
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
    await restoreSelectionIfNeeded()
    return result
  }

  /// Closes and forgets the open, opening, failed and remembered note when it no longer exists.
  private func forget(accountID: UUID, where gone: (NotebookSelection) -> Bool) {
    if let loaded = loadedDocument, gone(loaded.selection) {
      loadedDocument = nil
      library.selectedNoteID = nil
    }
    if let selection = opening?.request.selection, gone(selection) {
      documentRequest = UUID()
      opening = nil
    }
    if let selection = selections.selection(accountID: accountID), gone(selection) {
      selections.clear(accountID: accountID)
    }
    files = files.filter { !gone($0.value.document.selection) }
  }

  /// Drops everything shown for the current account and switches to `account`, or signs out.
  private func reset(to account: Account?) {
    libraryRequest = UUID()
    documentRequest = UUID()
    self.account = account
    pendingAccount = nil
    loadedDocument = nil
    opening = nil
    files = [:]
    localDrafts = []
    cachedLibrary = nil
    documentError = nil
    remoteRefreshProblem = nil
    writeFailure = nil
    isRefreshingRemote = false
    library.replaceSnapshot(nil)
    library.selectedNoteID = nil
    library.clearFilters()
    if account == nil { library.loadState = .signedOut }
  }

  /// A gist belongs to the signed-in account when its owner's login matches, ignoring case as
  /// GitHub does.
  func owns(_ gist: Gist) -> Bool {
    guard let account, let login = gist.owner?.login else { return false }
    return login.caseInsensitiveCompare(account.login) == .orderedSame
  }

  /// A note's header and actions, read from its gist, the account's preferences and the drafts on
  /// this iPhone, so it's always current.
  func chrome(for document: NotebookDocument) -> NoteChrome {
    let title =
      document.gist?.displayName
      ?? document.draft.flatMap { $0.description.isEmpty ? nil : $0.description }
      ?? String(localized: "Untitled")
    guard let gist = document.gist, let account, account.id == document.accountID else {
      return NoteChrome(
        title: title, files: [.init(id: document.filename, filename: document.filename)],
        selectedFileID: document.filename,
        isAutoSaveEnabled: account?.id == document.accountID
          && account?.preferences.isAutoSaveEnabled == true)
    }
    // A file added on this iPhone shows until it reaches GitHub or is deleted.
    let files = Set(
      gist.markdownFilenames
        + localDrafts.filter {
          $0.gistID == gist.id
            && (gist.files[$0.filename] != nil || $0.state != .savedToGitHub)
        }.map(\.filename)
    ).sorted()
    return NoteChrome(
      title: title,
      files: files.map { .init(id: $0, filename: $0) }, selectedFileID: document.filename,
      access: owns(gist) ? .editable : .readOnly,
      isPinned: account.preferences.pinnedGists.contains(gist.id),
      isStarred: cachedLibrary?.starred.contains(where: { $0.id == gist.id }) ?? false,
      isArchived: gist.isArchived,
      tags: library.snapshot.tags.filter {
        account.preferences.gistTags[gist.id]?.contains($0.id) == true
      },
      isAutoSaveEnabled: account.preferences.isAutoSaveEnabled,
      commentCount: gist.isDailyNote ? nil : gist.commentCount,
      shareURL: document.isRecovery || gist.files[document.filename] == nil
        ? nil : try? DocumentLinks(gist: gist, filename: document.filename).shareURL)
  }

  func adoptPublication(_ saved: DraftSnapshot) async throws -> Gist? {
    guard let account, account.id == saved.accountID, let id = saved.gistID else { return nil }
    let gist: Gist
    if let acknowledged = cachedLibrary?.details[id],
      acknowledged.revision == saved.baseRevision,
      let text = cachedLibrary?.content(gist: acknowledged, filename: saved.filename),
      let base = saved.baseContent, text.utf8.elementsEqual(base.utf8)
    {
      gist = acknowledged
    } else {
      gist = try await provider.gist(id: id, accountID: account.id)
      guard self.account?.id == account.id else { throw AccountError.accountChanged }
      if var cache = cachedLibrary {
        cache.owned.removeAll { $0.id == id }
        if owns(gist) { cache.owned.insert(gist, at: 0) }
        cache.starred = cache.starred.map { $0.id == id ? gist : $0 }
        try await provider.cacheLibrary(owned: cache.owned, starred: cache.starred, account: account)
        try await reloadLocalState(accountID: account.id)
      }
    }
    apply(published: saved, gist: gist)
    return gist
  }

  /// Points the open document at the gist it published to, keeping it selected under its new row.
  private func apply(published saved: DraftSnapshot, gist: Gist) {
    guard
      loadedDocument?.draft?.id == saved.id
        || (loadedDocument?.gist?.id == gist.id && loadedDocument?.filename == saved.filename)
    else { return }
    let wasSelected = library.selectedNoteID == loadedDocument?.rowID
    loadedDocument?.gist = gist
    loadedDocument?.draft = saved
    if loadedDocument?.libraryRowID == saved.id.uuidString { loadedDocument?.libraryRowID = nil }
    if wasSelected, opening == nil {
      library.selectedNoteID = loadedDocument?.rowID
      remember(NotebookSelection(gistID: gist.id, filename: saved.filename, draftID: saved.id))
    }
  }

  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> DraftSnapshot
  {
    let saved = try await provider.persist(
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

  /// Publishes each note with unpublished edits, in order, through its editor when it's open. The
  /// first offline result stops the sweep, and the next launch or return to the app retries it.
  func publishUnsyncedEdits() async {
    guard let accountID = account?.id, pendingAccount == nil else { return }
    let ids = localDrafts.filter { $0.accountID == accountID && $0.hasUnpublishedEdits }.map(\.id)
    for id in ids {
      guard !Task.isCancelled else { break }
      let state: PublishState?
      if let file = files[id] {
        await file.publish(reason: .background)
        state = file.draft.state
      } else {
        _ = try? await publish(draftID: id, accountID: accountID, reason: .background)
        state = (try? await draftSnapshot(id: id, accountID: accountID))?.state
      }
      if state == .failed(.network) { break }
    }
    try? await reloadLocalState(accountID: accountID)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason = .manual,
    expectedGeneration: UInt64? = nil,
    shouldPublish: @escaping @Sendable () async -> Bool = { true }
  ) async throws -> DraftSnapshot {
    guard account?.id == accountID || reason == .manual, pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    let saved: DraftSnapshot
    do {
      saved = try await provider.publish(
        draftID: draftID, accountID: accountID, reason: reason,
        expectedGeneration: expectedGeneration, shouldPublish: shouldPublish)
    } catch {
      if account?.id == accountID, pendingAccount == nil {
        recordWriteFailure(.note(draftID: draftID), accountID: accountID, error: error)
      }
      throw error
    }
    if saved.state == .savedToGitHub {
      clearWriteFailure { if case .note(draftID) = $0 { true } else { false } }
    }
    if account?.id == accountID {
      libraryRequest = UUID()
      isRefreshingRemote = false
      if library.loadState == .loading { library.loadState = .ready }
      try await reloadLocalState(accountID: accountID)
      if let gist = cachedLibrary?.gists.first(where: { $0.id == saved.gistID }) {
        apply(published: saved, gist: gist)
      }
    }
    return saved
  }

  static func librarySnapshot(
    owned: [Gist], starred: [Gist], account: Account, drafts: [DraftSnapshot] = [],
    cached: CachedLibrarySnapshot? = nil
  )
    -> LibrarySnapshot
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
    var notes = unique.values.flatMap { gist -> [LibraryNote] in
      let gistDrafts = drafts.filter { $0.gistID == gist.id }
      let days: [(filename: String, date: Date)?]
      if gist.isDailyNote, ownedIDs.contains(gist.id) {
        days = Set(gist.files.keys).union(gistDrafts.map(\.filename)).compactMap { filename in
          DailyNotesIndex.parseDateFilename(filename).map { (filename: filename, date: $0) }
        }.map(Optional.some)
      } else {
        days = [nil]
      }
      return days.map { day in
        var note = LibraryNote(
          id: day.map { "\(gist.id)/\($0.filename)" } ?? gist.id,
          title: day.map { GistConventions.fileDisplayName($0.filename) } ?? gist.displayName,
          updatedAt: gist.updatedAt, gistID: gist.id,
          owner: gist.owner?.login, isOwned: ownedIDs.contains(gist.id),
          isSecret: !gist.isPublic, isPinned: preferences.pinnedGists.contains(gist.id),
          isStarred: starredIDs.contains(gist.id), isArchived: gist.isArchived,
          isDailyNote: gist.isDailyNote, tagIDs: Set(preferences.gistTags[gist.id] ?? []),
          filename: day?.filename,
          dailyDate: day?.date,
          commentCount: gist.isDailyNote ? nil : gist.commentCount
        )
        // Only daily rows read note content, for their task progress.
        if gist.isDailyNote {
          let filename = day?.filename ?? GistConventions.todayFilename()
          let inline = gist.files[filename].flatMap {
            $0.truncated == true ? nil : $0.content
          }.map(GistConventions.decodeContent)
          updateLibraryContent(&note, text: librarySource(
            draft: gistDrafts.first { $0.filename == filename },
            cached: cached?.content(gist: gist, filename: filename) ?? inline))
        }
        return note
      }
    }
    notes += drafts.filter { $0.gistID.map { unique[$0] == nil } ?? true }.compactMap { draft in
      let daily = draft.description == GistConventions.dailyNotesDescription
      let day = daily ? DailyNotesIndex.parseDateFilename(draft.filename) : nil
      if daily, day == nil { return nil }
      var note = LibraryNote(
        id: draft.id.uuidString,
        title: daily ? GistConventions.fileDisplayName(draft.filename)
          : (draft.description.isEmpty ? String(localized: "Untitled") : draft.description),
        updatedAt: draft.updatedAt, isRecovery: draft.gistID != nil,
        isSecret: true, isDailyNote: daily, filename: draft.filename,
        dailyDate: day)
      updateLibraryContent(&note, text: draft.text)
      return note
    }
    let hasIncompleteDaily = unique.values.contains {
      ownedIDs.contains($0.id) && $0.isDailyNote && $0.truncated == true
    }
    return LibrarySnapshot(
      notes: notes.sorted {
        if $0.updatedAt != $1.updatedAt {
          return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        return $0.id < $1.id
      },
      tags: preferences.tagDefinitions.map { tag in
        LibraryTag(id: tag.id, name: tag.name, colorHex: tag.colorHex)
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      dailyNoteCount: hasIncompleteDaily ? nil : notes.filter {
        $0.isDailyNote && $0.isOwned && $0.dailyDate != nil
      }.count
    )
  }

  private func report(_ error: any Error, operation: String) {
    logger.error(
      "Notebook \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)"
    )
  }
}
