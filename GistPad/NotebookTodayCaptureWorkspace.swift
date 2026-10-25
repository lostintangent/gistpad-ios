#if DEBUG
import GistPadPlatform
import GistPadSync
import SwiftUI

struct NotebookTodayCaptureWorkspace: View {
  @State private var notebook: NotebookModel?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let notebook {
        LiveNotebookWorkspace(notebook: notebook, routes: NotebookRouteInbox())
      } else if let errorMessage {
        ContentUnavailableView("Today fixture unavailable", systemImage: "exclamationmark.circle",
                               description: Text(errorMessage))
      } else {
        ProgressView()
      }
    }
    .task {
      guard notebook == nil, errorMessage == nil else { return }
      let arguments = ProcessInfo.processInfo.arguments
      let scenario = arguments.firstIndex(of: "--today-fixture").flatMap { index in
        arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
      } ?? "cold"
      let provider = TodayCaptureProvider(scenario: scenario)
      let selections = NotebookSelectionStore()
      do {
        if scenario == "missing" || scenario == "existing" {
          try selections.save(
            .init(gistID: "other", filename: "README.md", draftID: nil),
            accountID: TodayCaptureProvider.account.id)
        }
        notebook = NotebookModel(provider: provider, selections: selections)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

private actor TodayCaptureProvider: NotebookProviding, NotebookPhotoProviding {
  static let account = NotebookAccount(
    id: UUID(uuidString: "C62D01E7-A38E-4CD0-855F-B845E8B48809")!,
    login: "synthetic-notebook", githubUserID: 1,
    preferences: .init(isAutoSaveEnabled: true, accentColor: nil))
  private let scenario: String
  private var store: DraftStore?
  private var todayAttempts = 0

  init(scenario: String) { self.scenario = scenario }

  func cachedAccount() -> NotebookAccount? { scenario == "signed-out" ? nil : Self.account }
  func signIn() -> NotebookAccount { Self.account }
  func refreshAccount() -> NotebookAccount { Self.account }
  func gists(accountID: UUID) throws -> [Gist] { try fixtureGists() }
  func starredGists(accountID: UUID) -> [Gist] { [] }

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
      return try await store.draft(id: draft.id, accountID: document.accountID)
    }
    guard let gist = document.gist else { throw GitHubClientError.missingFile }
    return try await store.openDraft(
      accountID: document.accountID, githubUserID: 1, gistID: gist.id,
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
    let store = try draftStore()
    return .init(
      library: try await store.cachedLibrary(accountID: accountID),
      drafts: try await store.drafts(accountID: accountID))
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) async throws {
    try await draftStore().cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id)
  }

  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    try await draftStore().createGistDraft(accountID: accountID, githubUserID: 1)
  }

  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await draftStore().discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }

  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    todayAttempts += 1
    if scenario == "retry", todayAttempts == 1 { throw URLError(.notConnectedToInternet) }
    let store = try draftStore()
    let client = GitHubClient { throw CaptureError.unsupported }
    return try await DailyNotesService(
      accountID: accountID, githubUserID: 1, client: client, store: store,
      coordinator: SyncCoordinator(client: client, store: store)).stageToday(target: target)
  }

  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    if case .inspectRemote(let id, let generation) = action {
      let store = try draftStore()
      let draft = try await store.draft(id: id, accountID: accountID)
      let gist = try fixtureGists().first { $0.id == draft.gistID }
      return .review(try await store.inspectRemoteChange(
        id: id, accountID: accountID, expectedGeneration: generation,
        remote: gist?.files[draft.filename]?.content, revision: gist?.revision))
    }
    throw CaptureError.unsupported
  }

  func photoServices(accountID: UUID) throws -> NotebookPhotoServices {
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

  private func fixtureGists() throws -> [Gist] {
    let dailyFilename = scenario == "existing" ? DailyNoteTarget().filename : "2026-10-01.md"
    let rows = [
      ("other", "A place for good ideas", "README.md", "Keep the useful things close."),
      ("daily", GistConventions.dailyNotesDescription, dailyFilename, "An existing daily thought."),
    ]
    let payload = rows.map { id, title, filename, text -> [String: Any] in
      [
        "id": id, "description": title, "public": false,
        "updated_at": "2026-10-25T00:00:00Z", "created_at": "2026-10-01T00:00:00Z",
        "owner": ["id": 1, "login": Self.account.login],
        "files": [filename: ["filename": filename, "language": "Markdown", "content": text]],
        "history": [["version": "synthetic-revision"]],
      ]
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Gist].self, from: JSONSerialization.data(withJSONObject: payload))
  }

  private enum CaptureError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This synthetic fixture never performs an account write." }
  }
}
#endif
