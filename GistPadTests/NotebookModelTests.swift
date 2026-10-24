import Foundation
import GistPadInterface
import Testing

@testable import GistPad
@testable import GistPadSync

@MainActor
struct NotebookModelTests {
  @Test func ordinaryGistOpensReadmeBeforeAnEarlierAlphabeticFileAndHonorsExplicitSelection() async throws {
    let gist = try makeGist(
      id: "multiple", title: "Multiple files", content: "Apple source", filename: "Apple.md",
      additionalFiles: ["README.md": "The actual README", "Zebra.md": "Zebra source"])
    let model = NotebookModel(provider: StubNotebookProvider(account: fixtureAccount, gists: [gist]))
    await model.start()
    await model.open(gistID: gist.id)
    #expect(model.loadedDocument?.filename == "README.md")
    #expect(model.loadedDocument?.text == "The actual README")
    await model.open(gistID: gist.id, filename: "Zebra.md")
    #expect(model.loadedDocument?.filename == "Zebra.md")
    #expect(model.loadedDocument?.text == "Zebra source")
  }

  @Test func accountSwitchKeepsAndExportsExactOriginalAccountDrafts() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Original account")])
    let model = NotebookModel(provider: provider)
    await model.start()
    let text = "日本語 e\u{301}\r\n**Private draft**"
    let local = try await provider.stageExistingDraft(gistID: "a", text: text)
    let replacement = NotebookAccount(
      id: UUID(), login: "other-account", preferences: .init(metadata: [:]))
    await provider.setSignInAccount(replacement)
    await model.signIn()
    let export = try await model.exportCurrentDrafts()
    let json = try #require(
      try JSONSerialization.jsonObject(with: export) as? [String: Any])
    let rows = try #require(json["drafts"] as? [[String: Any]])
    #expect(json["accountID"] as? String == fixtureAccount.id.uuidString)
    #expect(rows.count == 1)
    #expect((rows.first?["text"] as? String)?.utf8.elementsEqual(text.utf8) == true)
    model.keepCurrentNotebook()
    #expect(model.account?.id == fixtureAccount.id)
    #expect(model.pendingAccount == nil)
    let state = try await provider.localState(accountID: fixtureAccount.id)
    #expect(state.drafts.first?.id == local.id)
    #expect(state.drafts.first?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(try await provider.localState(accountID: replacement.id).drafts.isEmpty)
  }

  @Test func archiveUndoRequiresTheExactAccountAndUnchangedRemoteMetadata() throws {
    let original = try makeGist(id: "a", title: "Caf\u{E9} [Archived]")
    let undo = NotebookArchiveUndo(
      accountID: fixtureAccount.id, gistID: "a", originalDescription: "Caf\u{E9}",
      archivedDescription: original.description ?? "", wasArchived: false)
    try undo.validate(gist: original, accountID: fixtureAccount.id)
    #expect(throws: AccountError.accountChanged) {
      try undo.validate(gist: original, accountID: UUID())
    }
    let renamed = try makeGist(id: "a", title: "Cafe\u{301} [Archived]")
    #expect(throws: NotebookActionError.archiveChangedElsewhere) {
      try undo.validate(gist: renamed, accountID: fixtureAccount.id)
    }
  }

  @Test func mapsOwnedStarredAndWebMetadataWithoutDuplicates() throws {
    let owned = try makeGist(id: "a", title: "A note")
    let starred = try makeGist(id: "b", title: "A shared note", owner: "someone")
    let snapshot = NotebookModel.librarySnapshot(
      owned: [owned], starred: [owned, starred], account: fixtureAccount
    )
    #expect(snapshot.notes.count == 2)
    let note = try #require(snapshot.notes.first { $0.id == "a" })
    #expect(note.isOwned)
    #expect(note.isStarred)
    #expect(note.isPinned)
    #expect(note.isSecret)
    #expect(note.tagIDs == ["ideas"])
    #expect(snapshot.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
    #expect(snapshot.notes.first { $0.id == "b" }?.isOwned == false)
  }

  @Test func refreshDoesNotReplaceAnOpenedDocumentOrFilters() async throws {
    let original = try makeGist(id: "a", title: "Original", content: "Original text")
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [original])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    model.library.query = "Original"
    model.library.selectedTagIDs = ["ideas"]
    await provider.setGists([
      try makeGist(id: "a", title: "Changed remotely", content: "Remote text")
    ])
    await model.refresh()
    #expect(model.library.snapshot.notes.first?.title == "Changed remotely")
    #expect(model.loadedDocument?.text == "Original text")
    #expect(model.library.query == "Original")
    #expect(model.library.selectedTagIDs == ["ideas"])
    #expect(model.library.openDocumentOutsideFilter?.id == "a")
  }

  @Test func anOlderOpenCannotReplaceTheNewerSelection() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "First"), try makeGist(id: "b", title: "Second")]
    )
    let model = NotebookModel(provider: provider)
    await model.start()
    await provider.holdRead(id: "a")
    let firstOpen = Task { await model.open(gistID: "a") }
    await provider.waitForHeldRead()
    await model.open(gistID: "b")
    await provider.releaseRead()
    await firstOpen.value
    #expect(model.loadedDocument?.gist?.id == "b")
    #expect(model.library.selectedNoteID == "b")
    #expect(!model.isOpeningDocument)
  }

  @Test func networkFailureKeepsExistingLibraryAndDocument() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "A note")]
    )
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    await provider.failRequests()
    await model.refresh()
    #expect(model.library.snapshot.notes.count == 1)
    #expect(model.loadedDocument?.gist?.id == "a")
    guard case .failed(let message) = model.library.loadState else {
      Issue.record("A failed refresh must remain visible.")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test func accountSwitchWaitsForLocalWorkDisposition() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "A note")]
    )
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    let replacement = NotebookAccount(
      id: UUID(), login: "another-person", preferences: .init(metadata: [:]))
    await provider.setSignInAccount(replacement)
    await model.signIn()
    #expect(model.account?.id == fixtureAccount.id)
    #expect(model.pendingAccount?.id == replacement.id)
    #expect(model.loadedDocument?.accountID == fixtureAccount.id)
    guard case .reconnectRequired = model.library.loadState else {
      Issue.record("An account switch must not silently adopt another account.")
      return
    }
  }

  @Test func uncertainCreatesAndReconnectsCannotPublish() {
    #expect(NotebookModel.interfaceSaveState(.savedLocally) == .savedLocally)
    #expect(NotebookModel.interfaceSaveState(.savedToGitHub) == .savedToGitHub)
    #expect(NotebookModel.interfaceSaveState(.reconnect) == .reconnectRequired)
    let uncertain = NotebookModel.interfaceSaveState(.failed(.creationUncertain))
    #expect(uncertain == .creationUncertain)
    #expect(!uncertain.canPublish)
    #expect(!NotebookModel.interfaceSaveState(.failed(.incompleteRemote)).canPublish)
    #expect(!NotebookModel.interfaceSaveState(.failed(.readOnly)).canPublish)
  }

  @Test func launchRestoresTheAccountScopedFileWithoutCreatingAnything() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Last chosen")])
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
    try selections.save(
      .init(gistID: "someone-elses-note", filename: "private.md", draftID: nil),
      accountID: UUID())
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "a")
    #expect(model.loadedDocument?.filename == "README.md")
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
    await model.refresh()
    #expect(model.loadedDocument?.gist?.id == "a")
  }

  @Test func missingTodayShowsALandingUntilTheExplicitStartAction() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    #expect(model.loadedDocument == nil)
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
    let target = DailyNoteTarget(
      date: Date(timeIntervalSince1970: 1_790_208_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    await model.startToday(target: target)
    #expect(await provider.todayTargets == [target])
    #expect(model.loadedDocument?.draft?.filename == target.filename)
  }

  @Test func launchOpensExistingTodayWithoutCallingTheCreatingService() async throws {
    let filename = GistConventions.todayFilename()
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "daily", title: GistConventions.dailyNotesDescription, filename: filename)
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "daily")
    #expect(model.loadedDocument?.filename == filename)
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
  }

  @Test func aMissingRemotePreservesTheLocalDraftAndItsGeneration() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let draft = try await provider.stageExistingDraft(
      gistID: "deleted", text: "Keep my exact draft")
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "deleted", filename: draft.filename, draftID: nil),
      accountID: fixtureAccount.id)
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(model.loadedDocument?.draft?.generation == 8)
    #expect(model.loadedDocument?.text == "Keep my exact draft")
    #expect(model.loadedDocument?.isRecovery == true)
    #expect(model.documentError != nil)
    #expect(await provider.creationCount == 0)
  }

  @Test func newNotesAreRealDurableLocalDraftsWithoutASyntheticGist() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.createNote()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    #expect(document.gist == nil)
    #expect(draft.gistID == nil)
    #expect(draft.state == .savedLocally)
    #expect(await provider.creationCount == 1)
    #expect(await provider.todayTargets.isEmpty)
    await model.refresh()
    await model.refresh()
    #expect(model.library.snapshot.notes.filter { $0.id == draft.id.uuidString }.count == 1)
  }

  @Test func anUnrelatedAccountCannotRestoreThePreviousAccountsSelection() async throws {
    let other = NotebookAccount(id: UUID(), login: "other", preferences: .init(metadata: [:]))
    let provider = StubNotebookProvider(account: other, gists: [])
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument == nil)
    #expect(await provider.readIDs.isEmpty)
  }

  @Test func searchFindsCachedBodyTextAndNamedTagsWithoutTitleRefiltering() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Ordinary title", content: "A needle phrase in the body."),
        try makeGist(id: "b", title: "Needle phrase", content: "An untagged note."),
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    model.library.query = "\"needle phrase\" tag:Ideas"
    await model.search()
    #expect(model.library.matchingNotes.map(\.id) == ["a"])
    guard case .results(_, let coverage) = model.library.searchState else {
      Issue.record("Full-text results must carry honest cache coverage.")
      return
    }
    #expect(coverage.totalDocuments == 2)
    #expect(coverage.documentsWithCachedContent == 2)
    model.library.query = "tag:Missing"
    await model.search()
    guard case .failed(let message) = model.library.searchState else {
      Issue.record("An unknown tag must be an explicit search error.")
      return
    }
    #expect(message.contains("Missing"))
    #expect(model.library.matchingNotes.isEmpty)
  }

  @Test func dailySearchRowsOpenTheirExactFile() async throws {
    let filename = GistConventions.todayFilename()
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "daily", title: GistConventions.dailyNotesDescription,
          content: "- [x] One\n- [ ] Two", filename: filename)
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    model.library.collection = .dailyNotes
    await model.search()
    let row = try #require(model.library.matchingNotes.first)
    #expect(row.id == "daily/\(filename)")
    #expect(row.progress == .init(completed: 1, total: 2))
    await model.openRow(id: row.id)
    #expect(model.loadedDocument?.filename == filename)
    #expect(model.library.selectedNoteID == row.id)
  }
}

private let fixtureAccount = NotebookAccount(
  id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
  login: "notebook-owner",
  preferences: .init(metadata: [
    "pinnedGists": .array([.string("a")]),
    "tags": .object(["ideas": .object(["name": .string("Ideas"), "color": .string("#EBC85A")])]),
    "gistTags": .object(["a": .array([.string("ideas")])]),
  ])
)

private func makeGist(
  id: String, title: String, content: String = "Synthetic text", owner: String = "notebook-owner",
  filename: String = "README.md", additionalFiles: [String: String] = [:]
) throws -> Gist {
  var files = additionalFiles
  files[filename] = content
  var filePayload: [String: [String: String]] = [:]
  for (name, source) in files {
    filePayload[name] = ["filename": name, "language": "Markdown", "content": source]
  }
  let json: [String: Any] = [
    "id": id, "description": title, "public": false,
    "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
    "owner": ["id": 1, "login": owner],
    "files": filePayload,
    "history": [["version": "synthetic-revision"]],
  ]
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: json))
}

private actor StubNotebookProvider: NotebookProviding {
  let account: NotebookAccount
  var signInAccount: NotebookAccount
  var notes: [Gist]
  var shouldFail = false
  var heldID: String?
  var heldRead: CheckedContinuation<Void, Never>?
  var readObserver: CheckedContinuation<Void, Never>?
  var cached: CachedLibrarySnapshot?
  var store: DraftStore?
  private(set) var creationCount = 0
  private(set) var todayTargets: [DailyNoteTarget] = []
  private(set) var readIDs: [String] = []

  init(account: NotebookAccount, gists: [Gist]) {
    self.account = account
    self.signInAccount = account
    self.notes = gists
  }

  func cachedAccount() -> NotebookAccount? { account }
  func signIn() -> NotebookAccount { signInAccount }
  func refreshAccount() throws -> NotebookAccount {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    return account
  }
  func gists(accountID: UUID) -> [Gist] { notes }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) async throws -> Gist {
    readIDs.append(id)
    if id == heldID {
      await withCheckedContinuation { continuation in
        heldRead = continuation
        readObserver?.resume()
        readObserver = nil
      }
    }
    guard let gist = notes.first(where: { $0.id == id }) else {
      throw GitHubClientError.missingFile
    }
    return gist
  }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    guard let content = gist.files[filename]?.content else { throw GitHubClientError.missingFile }
    return GistConventions.decodeContent(content)
  }
  func openDraft(for document: NotebookDocument) throws -> DraftSnapshot {
    throw DraftError.notFound
  }
  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) throws
    -> DraftSnapshot
  {
    throw DraftError.notFound
  }
  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) throws -> DraftSnapshot { throw DraftError.notFound }
  func perform(_ action: NotebookAction, accountID: UUID) throws -> NotebookActionResult {
    throw DraftError.notFound
  }
  func localState(accountID: UUID) async throws -> NotebookLocalState {
    let drafts = try await store?.drafts(accountID: accountID) ?? []
    return NotebookLocalState(library: cached, drafts: drafts)
  }
  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {
    cached = CachedLibrarySnapshot(
      accountID: account.id, owned: owned, starred: starred, preferences: account.preferences)
  }
  private func draftStore() throws -> DraftStore {
    if let store { return store }
    let new = try DraftStore.open(inMemory: true)
    store = new
    return new
  }
  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    creationCount += 1
    return try await draftStore().createGistDraft(accountID: accountID, githubUserID: 1)
  }
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    todayTargets.append(target)
    let draft = try await draftStore().dailyGistDraft(
      accountID: accountID, githubUserID: 1, target: target)
    return TodayNote(target: target, gist: nil, draft: draft)
  }
  func stageExistingDraft(gistID: String, text: String) async throws -> DraftSnapshot {
    let store = try draftStore()
    let draft = try await store.openDraft(
      accountID: account.id, githubUserID: 1, gistID: gistID, filename: "README.md",
      description: "Recoverable note", content: "Base", revision: "1")
    return try await store.persist(id: draft.id, accountID: account.id, text: text, generation: 8)
  }
  func setGists(_ gists: [Gist]) { notes = gists }
  func failRequests() { shouldFail = true }
  func setSignInAccount(_ account: NotebookAccount) { signInAccount = account }
  func holdRead(id: String) { heldID = id }
  func waitForHeldRead() async {
    if heldRead != nil { return }
    await withCheckedContinuation { readObserver = $0 }
  }
  func releaseRead() {
    heldRead?.resume()
    heldRead = nil
    heldID = nil
  }
}
