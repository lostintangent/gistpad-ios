import AuthenticationServices
import Foundation
import GistPadEditor
import GistPadInterface
import GistPadSync
import OSLog
import Observation

struct NotebookAccount: Equatable, Sendable, Identifiable {
  let id: UUID
  let login: String
  let githubUserID: Int64?
  let preferences: Preferences

  init(id: UUID, login: String, githubUserID: Int64? = nil, preferences: Preferences) {
    self.id = id
    self.login = login
    self.githubUserID = githubUserID
    self.preferences = preferences
  }

  init(_ snapshot: AccountSnapshot) {
    self.init(
      id: snapshot.id, login: snapshot.login, githubUserID: snapshot.githubUserID,
      preferences: snapshot.preferences)
  }
}

protocol NotebookProviding: Sendable {
  func cachedAccount() async throws -> NotebookAccount?
  func signIn() async throws -> NotebookAccount
  func refreshAccount() async throws -> NotebookAccount
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
  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) async throws
  func createDraft(accountID: UUID) async throws -> DraftSnapshot
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult
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

  private func client(accountID: UUID) async -> GitHubClient {
    if let client = clients[accountID] { return client }
    let client = await accounts.githubClient(accountID: accountID)
    if let existing = clients[accountID] { return existing }
    clients[accountID] = client
    return client
  }

  func cachedAccount() async throws -> NotebookAccount? {
    try await accounts.cachedAccount().map(NotebookAccount.init)
  }

  func signIn() async throws -> NotebookAccount {
    NotebookAccount(try await accounts.signIn())
  }

  func refreshAccount() async throws -> NotebookAccount {
    NotebookAccount(try await accounts.refreshAccount())
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
    if let draft = document.draft {
      return try await drafts.draft(id: draft.id, accountID: document.accountID)
    }
    guard let gist = document.gist else { throw GitHubClientError.missingFile }
    guard let account = try await accounts.cachedAccount(), account.id == document.accountID else {
      throw AccountError.accountChanged
    }
    let githubUserID = try await verifiedUserID(accountID: document.accountID)
    let existing = try await drafts.drafts(accountID: document.accountID).first {
      $0.gistID == gist.id && $0.filename == document.filename
    }
    guard let existing else {
      return try await drafts.openDraft(
        accountID: document.accountID, githubUserID: githubUserID,
        gistID: gist.id, filename: document.filename,
        description: gist.description ?? "",
        content: document.text, revision: gist.revision
      )
    }
    return existing
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

  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) async throws {
    try await drafts.cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id)
  }

  private func verifiedUserID(accountID: UUID) async throws -> Int64 {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    if let id = account.githubUserID { return id }
    if let previous = try await drafts.drafts(accountID: accountID).first {
      return previous.githubUserID
    }
    throw AccountError.reconnectGitHub
  }

  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    let userID = try await verifiedUserID(accountID: accountID)
    return try await drafts.createGistDraft(accountID: accountID, githubUserID: userID)
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
  var chrome: NoteChrome
  var draft: DraftSnapshot?
  var isRecovery: Bool
  var libraryRowID: String?
  var opensForEditing = false
  let id: String

  init(accountID: UUID, gist: Gist, filename: String, text: String, chrome: NoteChrome) {
    self.accountID = accountID
    self.gist = gist
    self.filename = filename
    self.text = text
    self.chrome = chrome
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
    let access: NoteAccess =
      if let gist {
        gist.owner?.id == draft.githubUserID ? .editable : .readOnly
      } else { .editable }
    chrome = NoteChrome(
      title: gist?.displayName
        ?? (draft.description.isEmpty
          ? String(localized: "Untitled") : draft.description),
      files: [
        .init(
          id: draft.filename, filename: draft.filename,
          date: gist?.fileDatesForGrouping[draft.filename])
      ],
      selectedFileID: draft.filename, access: access)
  }

  var selection: NotebookSelection {
    NotebookSelection(gistID: gist?.id ?? draft?.gistID, filename: filename, draftID: draft?.id)
  }

  var rowID: String { libraryRowID ?? gist?.id ?? draft?.id.uuidString ?? id }

  func refersToSameFile(as other: NotebookDocument) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if let draftID = draft?.id, draftID == other.draft?.id { return true }
    if let gistID = selection.gistID { return gistID == other.selection.gistID }
    return false
  }
}

struct NotebookOpeningDocument: Equatable {
  let rowID: String
  let title: String
}

@MainActor @Observable
final class NotebookModel {
  let library = LibraryModel()
  private(set) var account: NotebookAccount?
  private(set) var pendingAccount: NotebookAccount?
  private(set) var loadedDocument: NotebookDocument?
  private(set) var isSigningIn = false
  private(set) var isOpeningDocument = false
  private(set) var openingDocument: NotebookOpeningDocument?
  private(set) var localDrafts: [DraftSnapshot] = []
  private(set) var cachedLibrary: CachedLibrarySnapshot?
  private(set) var isCreating = false
  private(set) var searchTargets: [String: NotebookSelection] = [:]
  private(set) var recoverySearchRows: Set<String> = []
  private(set) var deletedGistIDs: Set<String> = []
  var documentError: String?

  @ObservationIgnored private let provider: any NotebookProviding
  @ObservationIgnored private let selections: NotebookSelectionStore
  @ObservationIgnored private var libraryRequest = UUID()
  @ObservationIgnored private var documentRequest = UUID()
  @ObservationIgnored private var searchRequest = UUID()
  @ObservationIgnored private var ownedGistIDs: Set<String> = []
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Notebook")

  init(
    provider: any NotebookProviding, selections: NotebookSelectionStore = NotebookSelectionStore()
  ) {
    self.provider = provider
    self.selections = selections
  }

  convenience init(publishableKey: String) throws {
    self.init(
      provider: LiveNotebookProvider(
        accounts: try AccountService(publishableKey: publishableKey),
        drafts: try DraftStore.open()
      ), selections: NotebookSelectionStore(defaults: .standard))
  }

  var presentedDocument: NotebookDocument? {
    if let openingDocument { return cachedDocument(rowID: openingDocument.rowID) }
    guard let selected = library.selectedNoteID else { return loadedDocument }
    if loadedDocument?.rowID == selected { return loadedDocument }
    return cachedDocument(rowID: selected)
  }

  var openingTitle: String? {
    if let openingDocument { return openingDocument.title }
    guard let selected = library.selectedNoteID,
      selected != loadedDocument?.rowID
    else { return nil }
    return opening(gistID: searchTargets[selected]?.gistID ?? selected, rowID: selected).title
  }

  @discardableResult
  func beginOpeningRow(id: String) -> Bool {
    guard account != nil, pendingAccount == nil else {
      documentError = String(localized: "Reconnect GitHub before opening this note.")
      return false
    }
    documentRequest = UUID()
    documentError = nil
    if let document = cachedDocument(rowID: id) {
      openingDocument = nil
      isOpeningDocument = false
      do { try present(document) } catch {
        report(error, operation: "remember-selection")
        documentError = Self.message(for: error)
      }
      return true
    }
    openingDocument = opening(gistID: searchTargets[id]?.gistID ?? id, rowID: id)
    isOpeningDocument = true
    library.selectedNoteID = id
    return false
  }

  func cachedDocument(rowID: String) -> NotebookDocument? {
    if let target = searchTargets[rowID] {
      if let draftID = target.draftID, let draft = localDrafts.first(where: { $0.id == draftID }) {
        return localDocument(draft, rowID: rowID)
      }
      if let gistID = target.gistID {
        return cachedDocument(gistID: gistID, filename: target.filename, rowID: rowID)
      }
      return nil
    }
    if let id = UUID(uuidString: rowID), let draft = localDrafts.first(where: { $0.id == id }) {
      return localDocument(draft, rowID: rowID)
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
    let fileDates = gist.fileDatesForGrouping
    var document = NotebookDocument(
      accountID: account.id, gist: gist, filename: selectedFilename, text: text,
      chrome: NoteChrome(
        title: gist.displayName,
        files: gist.markdownFilenames.map { .init(id: $0, filename: $0, date: fileDates[$0]) },
        selectedFileID: selectedFilename,
        access: ownedGistIDs.contains(gistID) ? .editable : .readOnly,
        isPinned: account.preferences.pinnedGists.contains(gistID),
        isStarred: cachedLibrary?.starred.contains(where: { $0.id == gistID }) ?? false,
        isArchived: gist.isArchived,
        isAutoSaveEnabled: account.preferences.isAutoSaveEnabled))
    document.libraryRowID = rowID
    return document
  }

  private func localDocument(_ draft: DraftSnapshot, rowID: String?) -> NotebookDocument {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
    var document = NotebookDocument(
      draft: draft, gist: gist,
      isRecovery: draft.gistID.map { deletedGistIDs.contains($0) || gist == nil } ?? false)
    document.chrome = chrome(gist: gist, draft: draft)
    document.libraryRowID = rowID
    return document
  }

  private func opening(gistID: String, rowID: String?) -> NotebookOpeningDocument {
    let id = rowID ?? gistID
    let results: [LibraryNote]
    if case .results(let notes, _) = library.searchState { results = notes } else { results = [] }
    return .init(
      rowID: id,
      title: (results + library.snapshot.notes).first(where: { $0.id == id })?.title
        ?? cachedLibrary?.gists.first(where: { $0.id == gistID })?.displayName
        ?? String(localized: "Note"))
  }

  private func present(_ document: NotebookDocument) throws {
    loadedDocument = document
    library.selectedNoteID = document.rowID
    if document.isRecovery {
      documentError = String(
        localized:
          "The GitHub note is unavailable. Your local draft is safe and can still be read or exported.")
    }
    try remember(document.selection)
  }

  private func recordLocalDraft(_ draft: DraftSnapshot) {
    localDrafts.removeAll { $0.id == draft.id }
    localDrafts.append(draft)
    if !library.snapshot.notes.contains(where: {
      $0.id == draft.gistID || $0.id == draft.id.uuidString
    }) {
      library.snapshot.notes.insert(
        .init(
          id: draft.id.uuidString,
          title: draft.description.isEmpty ? String(localized: "Untitled") : draft.description,
          updatedAt: .now, isSecret: true,
          isDailyNote: draft.description == GistConventions.dailyNotesDescription),
        at: 0)
    }
    updateToday()
  }

  func start() async {
    let request = UUID()
    libraryRequest = request
    library.loadState = .loading
    do {
      let restored = try await provider.cachedAccount()
      guard request == libraryRequest else { return }
      guard let restored else {
        library.loadState = .signedOut
        return
      }
      account = restored
      deletedGistIDs = selections.deletedGistIDs(accountID: restored.id)
      try await reloadLocalState(accountID: restored.id)
      await refresh()
      await restoreSelectionIfNeeded()
    } catch is CancellationError {
      if request == libraryRequest {
        library.loadState = account == nil ? .signedOut : .ready
      }
    } catch {
      guard request == libraryRequest else { return }
      report(error, operation: "restore")
      library.loadState = .failed(message: Self.message(for: error))
    }
  }

  func signIn() async {
    guard !isSigningIn else { return }
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
              "A different GitHub account signed in. Keep or export the current account's drafts before switching."
          ))
        return
      }
      account = signedIn
      pendingAccount = nil
      await refresh()
      await restoreSelectionIfNeeded()
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      library.loadState = previousState
    } catch is CancellationError {
      library.loadState = previousState
    } catch {
      libraryRequest = UUID()
      report(error, operation: "sign-in")
      library.loadState = .reconnectRequired(message: Self.message(for: error))
    }
  }

  // The app calls this only after resolving the previous account's local work.
  func acceptPendingAccount() async {
    guard let pendingAccount else { return }
    libraryRequest = UUID()
    documentRequest = UUID()
    account = pendingAccount
    deletedGistIDs = selections.deletedGistIDs(accountID: pendingAccount.id)
    self.pendingAccount = nil
    loadedDocument = nil
    openingDocument = nil
    localDrafts = []
    cachedLibrary = nil
    documentError = nil
    isOpeningDocument = false
    ownedGistIDs = []
    library.snapshot = .init(notes: [])
    library.selectedNoteID = nil
    library.clearFilters()
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

  func exportCurrentDrafts() async throws -> Data {
    guard let account else { throw AccountError.signedOut }
    struct Export: Encodable {
      let formatVersion = 1
      let accountID: UUID
      let login: String
      let drafts: [ExportedDraft]
    }
    struct ExportedDraft: Encodable {
      let id: UUID
      let gistID: String?
      let filename: String
      let title: String
      let text: String
      let generation: UInt64
    }
    let local = try await provider.localState(accountID: account.id)
    guard self.account?.id == account.id else { throw AccountError.accountChanged }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      Export(
        accountID: account.id, login: account.login,
        drafts: local.drafts.map {
          ExportedDraft(
            id: $0.id, gistID: $0.gistID, filename: $0.filename,
            title: $0.description, text: $0.text, generation: $0.generation)
        }))
  }

  func updateCalendar() async {
    updateToday()
    await search()
  }

  func refresh() async {
    guard pendingAccount == nil else { return }
    guard let account else {
      await start()
      return
    }
    let request = UUID()
    libraryRequest = request
    let previousState = library.loadState
    library.loadState = .loading
    do {
      let refreshed = try await provider.refreshAccount()
      guard request == libraryRequest else { return }
      guard refreshed.id == account.id else { throw AccountError.accountChanged }
      async let owned = provider.gists(accountID: account.id)
      async let starred = provider.starredGists(accountID: account.id)
      let (ownedGists, starredGists) = try await (owned, starred)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      try await provider.cacheLibrary(owned: ownedGists, starred: starredGists, account: refreshed)
      guard request == libraryRequest, self.account?.id == account.id else { return }
      self.account = refreshed
      ownedGistIDs = Set(ownedGists.map(\.id))
      library.snapshot = Self.librarySnapshot(
        owned: ownedGists, starred: starredGists, account: refreshed)
      library.loadState = .ready
      try await reloadLocalState(accountID: account.id)
    } catch is CancellationError {
      if request == libraryRequest { library.loadState = previousState }
    } catch {
      guard request == libraryRequest else { return }
      report(error, operation: "refresh")
      library.loadState =
        Self.isAuthorizationError(error)
        ? .reconnectRequired(message: Self.message(for: error))
        : .failed(message: Self.message(for: error))
    }
  }

  func open(gistID: String, filename: String? = nil, rowID: String? = nil) async {
    guard pendingAccount == nil, let account else {
      documentError = String(localized: "Reconnect GitHub before opening this note.")
      return
    }
    let request = UUID()
    documentRequest = request
    isOpeningDocument = true
    openingDocument = opening(gistID: gistID, rowID: rowID)
    documentError = nil
    defer {
      if request == documentRequest {
        isOpeningDocument = false
        openingDocument = nil
      }
    }
    do {
      if let document = cachedDocument(gistID: gistID, filename: filename, rowID: rowID) {
        try present(document)
        return
      }
      let gist = try await provider.gist(id: gistID, accountID: account.id)
      guard request == documentRequest, self.account?.id == account.id, pendingAccount == nil else {
        return
      }
      let filenames = gist.markdownFilenames
      let fileDates = gist.fileDatesForGrouping
      let selectedFilename: String?
      if let filename {
        selectedFilename = filenames.contains(filename) ? filename : nil
      } else if gist.isDailyNote {
        let today = GistConventions.todayFilename()
        selectedFilename = filenames.contains(today) ? today : nil
      } else {
        selectedFilename = gist.defaultMarkdownFilename
      }
      guard let selectedFilename else { throw GitHubClientError.missingFile }
      let text = try await provider.content(
        gist: gist, filename: selectedFilename, accountID: account.id)
      guard request == documentRequest, self.account?.id == account.id, pendingAccount == nil else {
        return
      }
      let owned =
        ownedGistIDs.contains(gist.id)
        || gist.owner?.login.caseInsensitiveCompare(account.login) == .orderedSame
      var document = NotebookDocument(
        accountID: account.id, gist: gist, filename: selectedFilename, text: text,
        chrome: NoteChrome(
          title: gist.displayName,
          files: filenames.map {
            NoteFile(id: $0, filename: $0, date: fileDates[$0])
          },
          selectedFileID: selectedFilename, access: owned ? .editable : .readOnly,
          isPinned: account.preferences.pinnedGists.contains(gist.id),
          isStarred: library.snapshot.notes.first { $0.id == gist.id }?.isStarred ?? false,
          isArchived: gist.isArchived,
          isAutoSaveEnabled: account.preferences.isAutoSaveEnabled
        )
      )
      document.libraryRowID = rowID
      try present(document)
    } catch is CancellationError {
      if request == documentRequest { library.selectedNoteID = loadedDocument?.rowID }
    } catch {
      guard request == documentRequest else { return }
      report(error, operation: "open")
      if var local = cachedDocument(gistID: gistID, filename: filename, rowID: rowID) {
        let missingGist: Bool
        if case GitHubClientError.http(let status, _) = error {
          missingGist = status == 404
        } else {
          missingGist = false
        }
        local.isRecovery =
          missingGist || (local.draft?.baseContent != nil && Self.isMissingRemote(error))
        loadedDocument = local
        library.selectedNoteID = loadedDocument?.rowID
        documentError =
          Self.isMissingRemote(error)
          ? String(
            localized:
              "The GitHub note is unavailable. Your local draft is safe and can still be read or exported."
          )
          : Self.message(for: error)
        return
      }
      documentError = Self.message(for: error)
      library.selectedNoteID = loadedDocument?.rowID
    }
  }

  func openLocalDraft(id: UUID, rowID: String? = nil) async {
    guard let account, pendingAccount == nil else { return }
    documentRequest = UUID()
    let request = documentRequest
    isOpeningDocument = true
    openingDocument = .init(
      rowID: rowID ?? id.uuidString,
      title: localDrafts.first(where: { $0.id == id })?.description ?? String(localized: "Note"))
    defer {
      if request == documentRequest {
        isOpeningDocument = false
        openingDocument = nil
      }
    }
    do {
      if !localDrafts.contains(where: { $0.id == id }) {
        try await reloadLocalState(accountID: account.id)
      }
      guard request == documentRequest, self.account?.id == account.id, pendingAccount == nil else {
        return
      }
      guard let draft = localDrafts.first(where: { $0.id == id }) else {
        throw DraftError.notFound
      }
      let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
      loadedDocument = NotebookDocument(
        draft: draft, gist: gist, isRecovery: draft.gistID != nil && gist == nil)
      loadedDocument?.libraryRowID = rowID
      if let id = draft.gistID, deletedGistIDs.contains(id) {
        loadedDocument?.isRecovery = true
      }
      if let document = loadedDocument { try present(document) }
    } catch {
      guard request == documentRequest, self.account?.id == account.id else { return }
      report(error, operation: "open-local")
      documentError = Self.message(for: error)
    }
  }

  func openRow(id: String) async {
    if let target = searchTargets[id] {
      if let draftID = target.draftID,
        recoverySearchRows.contains(id)
          || localDrafts.contains(where: { $0.id == draftID && $0.baseContent == nil })
      {
        await openLocalDraft(id: draftID, rowID: id)
      } else if let gistID = target.gistID {
        await open(gistID: gistID, filename: target.filename, rowID: id)
      } else if let draftID = target.draftID {
        await openLocalDraft(id: draftID)
      }
    } else if let draftID = UUID(uuidString: id),
      localDrafts.contains(where: { $0.id == draftID })
    {
      await openLocalDraft(id: draftID)
    } else {
      await open(gistID: id)
    }
  }

  func search() async {
    searchRequest = UUID()
    let request = searchRequest
    guard let cache = cachedLibrary, let account else {
      library.searchState = .inactive
      return
    }
    guard library.hasFilters || library.collection == .dailyNotes else {
      library.searchState = .inactive
      searchTargets = [:]
      recoverySearchRows = []
      if loadedDocument?.libraryRowID != nil {
        let isSelected = library.selectedNoteID == loadedDocument?.rowID
        loadedDocument?.libraryRowID = nil
        if isSelected, openingDocument == nil { library.selectedNoteID = loadedDocument?.rowID }
      }
      return
    }
    do {
      let query = try LibrarySearchQuery(
        query: library.query, preferences: cache.preferences, tagIDs: library.selectedTagIDs)
      let collection: CachedLibraryCollection =
        switch library.collection {
        case .gists: .gists
        case .dailyNotes: .dailyNotes
        case .starred: .starred
        case .archive: .archive
        }
      let drafts = localDrafts.filter { draft in
        guard let gist = cache.owned.first(where: { $0.id == draft.gistID }),
          gist.isDailyNote, gist.files[draft.filename] == nil
        else { return true }
        return draft.state != .savedToGitHub || draft.attemptedGeneration != nil
      }
      library.searchState = .searching
      let result = await Task.detached(priority: .userInitiated) {
        LibrarySearch.search(cache, query: query, collection: collection, drafts: drafts)
      }.value
      guard !Task.isCancelled, request == searchRequest, self.account?.id == account.id else {
        return
      }
      var targets: [String: NotebookSelection] = [:]
      var recoveries: Set<String> = []
      let notes = result.matches.map { match in
        let gist = cache.gists.first { $0.id == match.gistID }
        let rowID =
          if let gist, !gist.isDailyNote, gist.markdownFilenames.count == 1 {
            gist.id
          } else { match.id }
        targets[rowID] = NotebookSelection(
          gistID: match.gistID, filename: match.filename, draftID: match.draftID)
        if match.isRecovery { recoveries.insert(rowID) }
        return LibraryNote(
          id: rowID, title: match.title, updatedAt: match.updatedAt, owner: gist?.owner?.login,
          isOwned: match.isRecovery || (match.gistID.map { ownedGistIDs.contains($0) } ?? true),
          isSecret: match.isSecret, isPinned: match.isPinned, isStarred: match.isStarred,
          isArchived: match.isArchived, isDailyNote: match.isDailyNote, tagIDs: match.tagIDs,
          filename: match.filename, fileCount: gist?.truncated == true ? nil : gist?.files.count,
          excerpt: match.text.map {
            String($0.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(160))
          },
          progress: match.progress.map { .init(completed: $0.completed, total: $0.total) },
          isOverdue: match.isOverdue)
      }
      searchTargets = targets
      recoverySearchRows = recoveries
      library.searchState = .results(
        notes: notes,
        coverage: .init(
          totalDocuments: result.totalDocuments,
          documentsWithCachedContent: result.documentsWithCachedContent,
          incompleteGistCount: result.incompleteGistIDs.count,
          staleResultCount: result.matches.filter { $0.text != nil && !$0.contentIsCurrent }.count))
    } catch {
      report(error, operation: "search")
      library.searchState = .failed(message: Self.searchMessage(error))
    }
  }

  private static func searchMessage(_ error: any Error) -> String {
    guard let error = error as? LibrarySearchError else { return message(for: error) }
    return switch error {
    case .unclosedQuote: String(localized: "Close the quotation marks to search for a phrase.")
    case .invalidEscape:
      String(localized: "Use a backslash only before another backslash or a quotation mark.")
    case .unknownTag(let name): String(localized: "No tag named “\(name)” exists.")
    case .ambiguousTag(let name):
      String(localized: "More than one tag is named “\(name)”. Search with its tag ID instead.")
    }
  }

  func createNote() async {
    guard let account, pendingAccount == nil, !isCreating else { return }
    isCreating = true
    documentRequest = UUID()
    let request = documentRequest
    openingDocument = .init(rowID: "new/\(request)", title: String(localized: "Untitled"))
    isOpeningDocument = false
    defer {
      isCreating = false
      if request == documentRequest { openingDocument = nil }
    }
    do {
      let draft = try await provider.createDraft(accountID: account.id)
      if self.account?.id == account.id { recordLocalDraft(draft) }
      guard request == documentRequest, self.account?.id == account.id else { return }
      var document = NotebookDocument(draft: draft)
      document.opensForEditing = true
      openingDocument = nil
      isOpeningDocument = false
      try present(document)
    } catch {
      report(error, operation: "create")
      documentError = Self.message(for: error)
    }
  }

  func startToday(target: DailyNoteTarget = DailyNoteTarget()) async {
    guard let account, pendingAccount == nil, !isCreating else { return }
    isCreating = true
    documentRequest = UUID()
    let request = documentRequest
    openingDocument = .init(rowID: "today/\(request)", title: String(localized: "Today"))
    isOpeningDocument = false
    defer {
      isCreating = false
      if request == documentRequest { openingDocument = nil }
    }
    do {
      let today = try await provider.today(accountID: account.id, target: target)
      if self.account?.id == account.id { recordLocalDraft(today.draft) }
      guard request == documentRequest, self.account?.id == account.id else { return }
      var document = NotebookDocument(draft: today.draft, gist: today.gist)
      document.opensForEditing = true
      openingDocument = nil
      isOpeningDocument = false
      try present(document)
    } catch {
      report(error, operation: "today")
      documentError = Self.message(for: error)
      do {
        try await reloadLocalState(accountID: account.id)
        if request == documentRequest,
          let local = localDrafts.first(where: {
            $0.filename == target.filename
              && $0.description == GistConventions.dailyNotesDescription
          })
        {
          loadedDocument = NotebookDocument(
            draft: local, gist: cachedLibrary?.gists.first { $0.id == local.gistID })
          library.selectedNoteID = loadedDocument?.rowID
        }
      } catch { report(error, operation: "reload-local") }
    }
  }

  func showToday() async {
    documentRequest = UUID()
    openingDocument = nil
    isOpeningDocument = false
    documentError = nil
    let daily = cachedLibrary?.owned.first(where: \.isDailyNote)
    let filename = GistConventions.todayFilename()
    if let draft = todayDraft(filename: filename, daily: daily) {
      await openLocalDraft(id: draft.id)
    } else if let daily, daily.files[filename] != nil {
      await open(gistID: daily.id, filename: filename)
    } else {
      loadedDocument = nil
      library.selectedNoteID = nil
    }
  }

  func remember(_ selection: NotebookSelection) throws {
    guard let account else { throw AccountError.signedOut }
    try selections.save(selection, accountID: account.id)
  }

  private func restoreSelectionIfNeeded() async {
    guard loadedDocument == nil, library.selectedNoteID == nil, let account,
      pendingAccount == nil
    else { return }
    do {
      if let selection = try selections.selection(accountID: account.id) {
        if let draftID = selection.draftID,
          localDrafts.contains(where: { $0.id == draftID })
        {
          await openLocalDraft(id: draftID)
          return
        }
        if let gistID = selection.gistID {
          await open(gistID: gistID, filename: selection.filename)
          if loadedDocument != nil { return }
        }
      }
      guard loadedDocument == nil, library.selectedNoteID == nil else { return }
      await showToday()
    } catch {
      report(error, operation: "restore-selection")
      documentError = String(
        localized: "Your previous selection couldn't be restored. Your notes are unchanged.")
    }
  }

  func reloadPlatformState(accountID: UUID) async throws {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    try await reloadLocalState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
  }

  private func reloadLocalState(accountID: UUID) async throws {
    let local = try await provider.localState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { return }
    localDrafts = local.drafts
    cachedLibrary = local.library
    if let cached = local.library, let account {
      ownedGistIDs = Set(cached.owned.map(\.id))
      library.snapshot = Self.librarySnapshot(
        owned: cached.owned, starred: cached.starred, account: account)
    } else {
      library.snapshot = .init(notes: [])
    }
    let known = Set(library.snapshot.notes.map(\.id))
    library.snapshot.notes += local.drafts.filter {
      $0.gistID.map { !known.contains($0) } ?? true
    }.map { draft in
      LibraryNote(
        id: draft.id.uuidString,
        title: draft.description.isEmpty ? String(localized: "Untitled") : draft.description,
        updatedAt: local.library?.cachedAt ?? .now,
        isSecret: true, isDailyNote: draft.description == GistConventions.dailyNotesDescription)
    }
    updateToday()
    await search()
  }

  private func updateToday() {
    let filename = GistConventions.todayFilename()
    let daily = cachedLibrary?.owned.first(where: \.isDailyNote)
    let local = todayDraft(filename: filename, daily: daily)
    let text = local?.text ?? daily.flatMap { cachedLibrary?.content(gist: $0, filename: filename) }
    var summary = LibraryTodaySummary(
      date: .now,
      progress: text.map {
        let tasks = TaskProgress(markdown: $0)
        return LibraryTaskProgress(completed: tasks.completed, total: tasks.total)
      })
    if local != nil || daily?.files[filename] != nil {
      summary.availability = .existing
    } else if cachedLibrary != nil, library.loadState == .ready, daily?.truncated != true {
      summary.availability = .missing
    }
    summary.excerpt = text.flatMap {
      let lines = $0.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n")
      let excerpt = String(lines.prefix(280)).trimmingCharacters(in: .whitespacesAndNewlines)
      return excerpt.isEmpty ? nil : excerpt
    }
    library.today = summary
  }

  private func todayDraft(filename: String, daily: Gist?) -> DraftSnapshot? {
    localDrafts.first {
      $0.filename == filename
        && ($0.description == GistConventions.dailyNotesDescription
          || (daily != nil && $0.gistID == daily?.id))
    }
  }
  private static func isMissingRemote(_ error: any Error) -> Bool {
    if case GitHubClientError.http(let status, _) = error { return status == 404 }
    return (error as? GitHubClientError) == .missingFile
  }

  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    try await provider.openDraft(for: document)
  }

  func draftSnapshot(id: UUID, accountID: UUID) async throws -> DraftSnapshot {
    guard
      let draft = try await provider.localState(accountID: accountID).drafts.first(where: {
        $0.id == id
      })
    else { throw DraftError.notFound }
    return draft
  }

  func photoServices(accountID: UUID) async throws -> NotebookPhotoServices {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    guard let provider = provider as? any NotebookPhotoProviding else {
      throw NotebookEditError.photoServicesUnavailable
    }
    return try await provider.photoServices(accountID: accountID)
  }

  func perform(_ action: NotebookAction) async throws -> NotebookActionResult {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    let result: NotebookActionResult
    do {
      result = try await provider.perform(action, accountID: account.id)
    } catch NotebookActionError.remoteDeletedLocalCleanupFailed(let id) {
      selections.markDeleted(gistID: id, accountID: account.id)
      if self.account?.id == account.id { deletedGistIDs.insert(id) }
      throw NotebookActionError.remoteDeletedLocalCleanupFailed(gistID: id)
    }
    guard self.account?.id == account.id else { throw AccountError.accountChanged }
    switch result {
    case .account(let updated):
      self.account = updated
      if let cache = cachedLibrary {
        try await provider.cacheLibrary(
          owned: cache.owned, starred: cache.starred, account: updated)
      }
    case .archived(let gist, _):
      if let cache = cachedLibrary {
        try await provider.cacheLibrary(
          owned: cache.owned.map { $0.id == gist.id ? gist : $0 },
          starred: cache.starred.map { $0.id == gist.id ? gist : $0 }, account: account)
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
      let document = NotebookDocument(draft: draft, gist: gist)
      loadedDocument = document
      library.selectedNoteID = document.rowID
      try selections.save(document.selection, accountID: account.id)
    case .deleted(let id, let disposition):
      selections.markDeleted(gistID: id, accountID: account.id)
      deletedGistIDs.insert(id)
      if loadedDocument?.selection.gistID == id {
        if let retained = disposition.retainedDrafts.first(where: {
          $0.filename == loadedDocument?.filename
        }) {
          loadedDocument = NotebookDocument(draft: retained, isRecovery: true)
        } else {
          loadedDocument = nil
        }
        library.selectedNoteID = loadedDocument?.rowID
      }
      if let cache = cachedLibrary {
        try await provider.cacheLibrary(
          owned: cache.owned.filter { $0.id != id }, starred: cache.starred.filter { $0.id != id },
          account: account)
      }
    case .review:
      break
    }
    try await reloadLocalState(accountID: account.id)
    return result
  }

  func chrome(gist: Gist?, draft: DraftSnapshot) -> NoteChrome {
    guard let gist, let account, account.id == draft.accountID else {
      var chrome = NotebookDocument(draft: draft).chrome
      chrome.isAutoSaveEnabled =
        account?.id == draft.accountID && account?.preferences.isAutoSaveEnabled == true
        && !draft.autosavePaused
      return chrome
    }
    let owned = ownedGistIDs.contains(gist.id) || gist.owner?.id == draft.githubUserID
    let fileDates = gist.fileDatesForGrouping
    let files = Set(
      gist.markdownFilenames
        + localDrafts.filter {
          $0.gistID == gist.id
            && (gist.files[$0.filename] != nil || $0.state != .savedToGitHub)
        }.map(\.filename)
    ).sorted()
    return NoteChrome(
      title: gist.displayName,
      files: files.map {
        .init(id: $0, filename: $0, date: fileDates[$0])
      }, selectedFileID: draft.filename,
      access: owned ? .editable : .readOnly,
      isPinned: account.preferences.pinnedGists.contains(gist.id),
      isStarred: cachedLibrary?.starred.contains(where: { $0.id == gist.id }) ?? false,
      isArchived: gist.isArchived,
      tags: library.snapshot.tags.filter {
        account.preferences.gistTags[gist.id]?.contains($0.id) == true
      },
      isAutoSaveEnabled: account.preferences.isAutoSaveEnabled && !draft.autosavePaused)
  }

  func refreshedGist(id: String, accountID: UUID) async throws -> Gist {
    try await provider.gist(id: id, accountID: accountID)
  }

  func adoptPublication(_ saved: DraftSnapshot) async throws -> Gist? {
    guard let account, account.id == saved.accountID, let id = saved.gistID else { return nil }
    let gist = try await provider.gist(id: id, accountID: account.id)
    guard self.account?.id == account.id else { throw AccountError.accountChanged }
    if var cache = cachedLibrary {
      let owned = cache.owned.contains { $0.id == id } || gist.owner?.id == saved.githubUserID
      cache.owned.removeAll { $0.id == id }
      if owned { cache.owned.insert(gist, at: 0) }
      cache.starred = cache.starred.map { $0.id == id ? gist : $0 }
      try await provider.cacheLibrary(owned: cache.owned, starred: cache.starred, account: account)
      try await reloadLocalState(accountID: account.id)
    }
    if loadedDocument?.draft?.id == saved.id
      || (loadedDocument?.gist?.id == id && loadedDocument?.filename == saved.filename)
    {
      let isSelected = library.selectedNoteID == loadedDocument?.rowID
      loadedDocument?.gist = gist
      loadedDocument?.draft = saved
      loadedDocument?.chrome = chrome(gist: gist, draft: saved)
      if isSelected, openingDocument == nil {
        library.selectedNoteID = loadedDocument?.rowID
        try remember(NotebookSelection(gistID: id, filename: saved.filename, draftID: saved.id))
      }
    }
    return gist
  }

  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> DraftSnapshot
  {
    let saved = try await provider.persist(
      draftID: draftID, accountID: accountID, text: text, generation: generation)
    if account?.id == accountID {
      localDrafts.removeAll { $0.id == saved.id }
      localDrafts.append(saved)
      updateToday()
      await search()
    }
    return saved
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason = .manual,
    expectedGeneration: UInt64? = nil,
    shouldPublish: @escaping @Sendable () async -> Bool = { true }
  ) async throws -> DraftSnapshot {
    guard account?.id == accountID || reason == .manual, pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    return try await provider.publish(
      draftID: draftID, accountID: accountID, reason: reason,
      expectedGeneration: expectedGeneration, shouldPublish: shouldPublish)
  }

  static func librarySnapshot(owned: [Gist], starred: [Gist], account: NotebookAccount)
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
    return LibrarySnapshot(
      notes: unique.values.map { gist in
        LibraryNote(
          id: gist.id, title: gist.displayName, updatedAt: gist.updatedAt,
          owner: gist.owner?.login, isOwned: ownedIDs.contains(gist.id),
          isSecret: !gist.isPublic, isPinned: preferences.pinnedGists.contains(gist.id),
          isStarred: starredIDs.contains(gist.id), isArchived: gist.isArchived,
          isDailyNote: gist.isDailyNote, tagIDs: Set(preferences.gistTags[gist.id] ?? []),
          fileCount: gist.truncated == true ? nil : gist.files.count
        )
      }.sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id < $1.id
      },
      tags: preferences.tags.map { id, value in
        LibraryTag(
          id: id, name: value.objectValue?["name"]?.stringValue ?? id,
          colorHex: value.objectValue?["color"]?.stringValue
        )
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    )
  }

  static func interfaceSaveState(_ state: SaveState) -> NoteSaveState {
    switch state {
    case .savedLocally: .savedLocally
    case .savingToGitHub: .savingToGitHub
    case .savedToGitHub: .savedToGitHub
    case .offline: .offline
    case .reconnect: .reconnectRequired
    case .conflict: .remoteChange
    case .failed(let failure):
      switch failure {
      case .creationUncertain: .creationUncertain
      case .publicationUncertain: .publicationUncertain
      case .readOnly:
        .publicationBlocked(
          message: String(localized: "This account no longer has permission to edit the gist."))
      case .incompleteRemote:
        .publicationBlocked(
          message: String(
            localized:
              "GitHub returned an incomplete note. Publishing could overwrite missing content."))
      case .network:
        .cloudFailure(
          message: String(
            localized:
              "GitHub couldn't confirm the save. Retry to check the remote version before publishing again."
          ))
      case .http(let status, _):
        .cloudFailure(
          message: message(for: GitHubClientError.http(status: status, retryAfter: nil)))
      }
    }
  }

  private func report(_ error: any Error, operation: String) {
    logger.error(
      "Notebook \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)"
    )
  }

  private static func isAuthorizationError(_ error: any Error) -> Bool {
    if let error = error as? AccountError {
      return error == .signedOut || error == .accountChanged || error == .reconnectGitHub
    }
    if case GitHubClientError.http(let status, _) = error { return status == 401 }
    return false
  }

  static func message(for error: any Error) -> String {
    if (error as? SourceMutation.MutationError) == .compositionActive {
      return String(
        localized: "Finish composition or Writing Tools before continuing. Your current draft is unchanged.")
    }
    if isAuthorizationError(error) {
      return String(
        localized: "GitHub access needs to be reconnected. Your local work has not been removed.")
    }
    if let error = error as? NotebookSharingError {
      return switch error {
      case .saveNotConfirmed:
        String(
          localized:
            "GitHub hasn't confirmed the current draft. Nothing was shared. Return to the note to review its save status."
        )
      case .draftChangedWhileSaving:
        String(
          localized:
            "Your draft changed while saving. Nothing was shared. Save the latest version or choose its saved link."
        )
      }
    }
    if error is DocumentLinkError {
      return String(
        localized:
          "This file doesn't have a verified saved link yet. Save it to GitHub or share the draft text instead."
      )
    }
    if let error = error as? NotebookEditError {
      return switch error {
      case .localPersistenceFailed:
        String(
          localized:
            "Your latest changes couldn't be saved on this iPhone. Keep the editor open and retry the local save."
        )
      case .invalidCommittedEdit:
        String(
          localized:
            "The accepted edit couldn't be matched to this editor. Keep it open to recover both versions."
        )
      case .photoServicesUnavailable:
        String(localized: "Photo uploading isn't available in this notebook.")
      }
    }
    if let error = error as? NotebookActionError {
      return switch error {
      case .invalidTitle: String(localized: "Enter a name for this note.")
      case .invalidFilename:
        String(localized: "Enter a Markdown filename ending in .md, without a slash.")
      case .filenameExists: String(localized: "A file or local draft already uses that name.")
      case .publicationInProgress:
        String(localized: "Finish or reconcile the current GitHub save before changing this note.")
      case .remoteChangedLocalUpdateFailed:
        String(
          localized:
            "The name changed on GitHub, but its local reference couldn't be updated. Your source is still in the editor. Reopen the note to reconcile it."
        )
      case .remoteDeletedLocalCleanupFailed:
        String(
          localized:
            "The note was deleted from GitHub, but local recovery cleanup couldn't finish. Local copies are preserved and publishing is blocked."
        )
      case .staleReview:
        String(localized: "Your draft changed while this review was open. Review the latest draft.")
      case .remoteReviewChanged:
        String(
          localized: "GitHub has a newer version. Refresh the review before applying this choice.")
      case .archiveChangedElsewhere:
        String(
          localized:
            "This note's details changed after archiving. Refresh the Library before changing its archive state. Nothing was overwritten."
        )
      }
    }
    if let error = error as? GitHubClientError {
      switch error {
      case .incompleteGist:
        return String(localized: "GitHub returned an incomplete note. It cannot be edited safely.")
      case .missingFile:
        return String(localized: "The requested Markdown file is not available in this gist.")
      case .fileTooLarge:
        return String(localized: "This file is too large to open safely.")
      case .http(let status, _) where status == 403 || status == 429:
        return String(
          localized:
            "GitHub is limiting requests or denied access. Try again later or reconnect your account."
        )
      case .http(let status, _) where status == 404:
        return String(localized: "This gist is no longer available to this account.")
      default:
        return String(localized: "GitHub couldn't provide this note. Try again.")
      }
    }
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet, .networkConnectionLost:
        return String(
          localized:
            "You're offline. Reconnect to update your notebook. Existing local work is unchanged.")
      case .timedOut:
        return String(localized: "The request timed out. Try again when your connection is stable.")
      default:
        break
      }
    }
    if let error = error as? AccountError, error == .invalidConfiguration {
      return String(localized: "GitHub sign-in isn't configured correctly in this build.")
    }
    return String(
      localized: "Your notebook couldn't be updated. Try again. Existing local work is unchanged.")
  }
}
