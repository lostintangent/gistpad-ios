import Foundation
import GistPadInterface
import Testing

@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct NotebookSessionTests {
  @Test func restoredGenerationsAndRapidEditsPersistInOrder() async throws {
    let (controller, provider) = try await makeController(generation: 7)
    #expect(controller.session.generation == 7)
    for text in ["First", "Second", "日本語 👨‍👩‍👧‍👦"] { edit(controller, to: text) }
    #expect(await controller.waitForLocalSave())
    let saved = try await provider.snapshot()
    #expect(saved.generation == 10)
    #expect(saved.text.utf8.elementsEqual("日本語 👨‍👩‍👧‍👦".utf8))
    #expect(await provider.persistedGenerations == [8, 9, 10])
    #expect(controller.saveState == .savedLocally)
  }

  @Test func aPublishResponseCannotReplaceNewerTyping() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "The manually saved generation")
    #expect(await controller.waitForLocalSave())
    let publishing = Task { await controller.publish() }
    await provider.waitForPublish()
    edit(controller, to: "Newer typing stays local")
    #expect(await controller.waitForLocalSave())
    await provider.releasePublish()
    await publishing.value
    #expect(controller.session.text == "Newer typing stays local")
    #expect(controller.draft.text == "Newer typing stays local")
    #expect(controller.draft.baseContent == "The manually saved generation")
    #expect(controller.saveState == .savedLocally)
  }

  @Test func aLocalWriteFailureBlocksPublishing() async throws {
    let (controller, provider) = try await makeController()
    await provider.failPersistence()
    edit(controller, to: "Keep this in the editor")
    #expect(!(await controller.waitForLocalSave()))
    await controller.publish()
    #expect(await provider.publishCount == 0)
    #expect(controller.session.text == "Keep this in the editor")
    guard case .localFailure = controller.saveState else {
      Issue.record("An unacknowledged local write must remain an explicit failure.")
      return
    }
  }

  @Test func lostOwnershipBlocksFurtherPublication() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "A local edit")
    #expect(await controller.waitForLocalSave())
    await provider.rejectPublication()
    await controller.publish()
    guard case .publicationBlocked = controller.saveState else {
      Issue.record("Lost ownership must not become a retryable network failure.")
      return
    }
    #expect(!controller.saveState.canPublish)
  }

  private func edit(_ controller: NotebookSessionController, to text: String) {
    controller.session.textView.text = text
    controller.session.textViewDidChange(controller.session.textView)
  }

  private func makeController(
    generation: UInt64 = 0
  ) async throws -> (NotebookSessionController, SessionNotebookProvider) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let gist = try decoder.decode(
      Gist.self,
      from: Data(
        """
        {"id":"synthetic","description":"Session fixture","public":false,
        "created_at":"2026-10-23T00:00:00Z","updated_at":"2026-10-23T00:00:00Z",
        "owner":{"id":1,"login":"fixture"},
        "files":{"README.md":{"filename":"README.md","content":"Base"}}}
        """.utf8))
    let accountID = UUID()
    let store = try DraftStore.open(inMemory: true)
    var draft = try await store.openDraft(
      accountID: accountID, githubUserID: 1, gistID: gist.id, filename: "README.md",
      description: "Session fixture", content: "Base", revision: "1")
    if generation > 0 {
      draft = try await store.persist(
        id: draft.id, accountID: accountID, text: "Restored local draft", generation: generation)
    }
    let provider = SessionNotebookProvider(store: store, id: draft.id, accountID: accountID)
    let model = NotebookModel(provider: provider)
    let document = NotebookDocument(
      accountID: accountID, gist: gist, filename: "README.md", text: "Base",
      chrome: NoteChrome(
        title: "Session fixture", files: [.init(id: "README.md", filename: "README.md")],
        selectedFileID: "README.md"))
    return (NotebookSessionController(document: document, draft: draft, notebook: model), provider)
  }
}

private actor SessionNotebookProvider: NotebookProviding {
  let store: DraftStore
  let id: UUID
  let accountID: UUID
  private(set) var persistedGenerations: [UInt64] = []
  private(set) var publishCount = 0
  private var persistenceFails = false
  private var publicationRejected = false
  private var publishing: CheckedContinuation<Void, Never>?
  private var publishObserver: CheckedContinuation<Void, Never>?

  init(store: DraftStore, id: UUID, accountID: UUID) {
    self.store = store
    self.id = id
    self.accountID = accountID
  }

  func cachedAccount() -> NotebookAccount? { nil }
  func signIn() throws -> NotebookAccount { throw AccountError.signedOut }
  func refreshAccount() throws -> NotebookAccount { throw AccountError.signedOut }
  func gists(accountID: UUID) -> [Gist] { [] }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) throws -> Gist { throw GitHubClientError.missingFile }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    throw GitHubClientError.missingFile
  }
  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    try await snapshot()
  }

  func persist(
    draftID: UUID, accountID: UUID, text: String, generation: UInt64
  ) async throws -> DraftSnapshot {
    if persistenceFails { throw URLError(.cannotWriteToFile) }
    persistedGenerations.append(generation)
    return try await store.persist(
      id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(draftID: UUID, accountID: UUID) async throws -> DraftSnapshot {
    publishCount += 1
    if publicationRejected { throw DraftError.readOnly }
    let sent = try await snapshot()
    try await store.beginAttempt(
      id: draftID, accountID: accountID, content: sent.text,
      generation: sent.generation, remote: sent.baseContent)
    await withCheckedContinuation {
      publishing = $0
      publishObserver?.resume()
      publishObserver = nil
    }
    return try await store.acknowledge(
      id: draftID, accountID: accountID, gistID: "synthetic",
      content: sent.text, revision: "2", generation: sent.generation)
  }

  func snapshot() async throws -> DraftSnapshot {
    try await store.draft(id: id, accountID: accountID)
  }

  func waitForPublish() async {
    if publishing != nil { return }
    await withCheckedContinuation { publishObserver = $0 }
  }

  func releasePublish() {
    publishing?.resume()
    publishing = nil
  }

  func failPersistence() { persistenceFails = true }
  func rejectPublication() { publicationRejected = true }
}
