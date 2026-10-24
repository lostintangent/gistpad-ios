#if DEBUG
import GistPadSync
import GistPadPlatform
import SwiftUI

struct NotebookLibraryDeletionCaptureWorkspace: View {
  @State private var notebook = NotebookModel(provider: LibraryDeletionCaptureProvider())

  var body: some View {
    LiveNotebookWorkspace(notebook: notebook, routes: NotebookRouteInbox())
  }
}

private actor LibraryDeletionCaptureProvider: NotebookProviding, NotebookPhotoProviding {
  private let account = NotebookAccount(
    id: UUID(), login: "synthetic-notebook", githubUserID: 1,
    preferences: .init(isAutoSaveEnabled: false, accentColor: nil))
  private var cache: CachedLibrarySnapshot?
  private var store: DraftStore?
  private var deleted: Set<String> = []

  func cachedAccount() -> NotebookAccount? { account }
  func signIn() -> NotebookAccount { account }
  func refreshAccount() -> NotebookAccount { account }
  func gists(accountID: UUID) throws -> [Gist] {
    try fixtureGists(
      includeDeleted: ProcessInfo.processInfo.arguments.contains("--capture-stale-deletion")
    ).filter { $0.id != "shared" }
  }
  func starredGists(accountID: UUID) throws -> [Gist] {
    try fixtureGists().filter { $0.id == "shared" }
  }

  func gist(id: String, accountID: UUID) throws -> Gist {
    guard let gist = try fixtureGists().first(where: { $0.id == id }) else {
      throw GitHubClientError.missingFile
    }
    return gist
  }

  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    guard let text = gist.files[filename]?.content else { throw GitHubClientError.missingFile }
    return text
  }

  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    let store = try draftStore()
    if let draft = document.draft {
      return try await store.draft(id: draft.id, accountID: account.id)
    }
    guard let gist = document.gist else { throw GitHubClientError.missingFile }
    return try await store.openDraft(
      accountID: account.id, githubUserID: 1, gistID: gist.id,
      filename: document.filename, description: gist.description ?? "",
      content: document.text, revision: gist.revision)
  }

  func persist(
    draftID: UUID, accountID: UUID, text: String, generation: UInt64
  ) async throws -> DraftSnapshot {
    try await draftStore().persist(
      id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason, expectedGeneration: UInt64?,
    shouldPublish: @escaping @Sendable () async -> Bool
  ) throws -> DraftSnapshot {
    throw CaptureError.unsupported
  }

  func localState(accountID: UUID) async throws -> NotebookLocalState {
    .init(library: cache, drafts: try await store?.drafts(accountID: accountID) ?? [])
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {
    cache = .init(
      accountID: account.id, owned: owned, starred: starred, preferences: account.preferences)
  }

  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    try await draftStore().createGistDraft(accountID: accountID, githubUserID: 1)
  }

  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await draftStore().discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }

  func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote {
    throw CaptureError.unsupported
  }

  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    guard accountID == account.id else { throw AccountError.accountChanged }
    guard case .delete(let id) = action, id != "shared",
      try fixtureGists().contains(where: { $0.id == id })
    else { throw CaptureError.unsupported }
    deleted.insert(id)
    return .deleted(
      gistID: id,
      drafts: try await draftStore().removeCleanDraftsForDeletedGist(
        gistID: id, accountID: accountID))
  }

  func photoServices(accountID: UUID) async throws -> NotebookPhotoServices {
    let store = try draftStore()
    let storage = try ImageStorageClient(publishableKey: "sb_publishable_fixture") {
      throw CaptureError.unsupported
    }
    return .init(
      store: store,
      uploads: ImageUploadCoordinator(accountID: accountID, store: store, storage: storage))
  }

  private func draftStore() throws -> DraftStore {
    if let store { return store }
    let created = try DraftStore.open(inMemory: true)
    store = created
    return created
  }

  private func fixtureGists(includeDeleted: Bool = false) throws -> [Gist] {
    let payload = [
      ("a", "A thought to keep"), ("b", "A finished thought"), ("shared", "A friend's field guide"),
    ].filter { includeDeleted || !deleted.contains($0.0) }.map { id, title -> [String: Any] in
      [
        "id": id, "description": title, "public": false,
        "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
        "owner": ["id": id == "shared" ? 2 : 1, "login": id == "shared" ? "a-friend" : account.login],
        "files": [
          "README.md": [
            "filename": "README.md", "language": "Markdown",
            "content": "# \(title)\n\nA synthetic note. No account request is made.",
          ],
        ],
        "history": [["version": "synthetic-revision"]],
      ]
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Gist].self, from: JSONSerialization.data(withJSONObject: payload))
  }

  private enum CaptureError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This synthetic fixture does not perform that account action." }
  }
}
#endif
