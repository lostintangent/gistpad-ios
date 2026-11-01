#if DEBUG
import Foundation
import GistPadSync
import GistPadPlatform
import SwiftUI

struct NotebookLibraryDeletionCaptureWorkspace: View {
  @State private var notebook = NotebookModel(provider: LibraryDeletionCaptureProvider())

  var body: some View {
    LiveNotebookWorkspace(notebook: notebook, routes: NotebookRouteInbox())
  }
}

actor LibraryDeletionCaptureProvider: NotebookProviding, NotebookPhotoProviding {
  private let account: NotebookAccount
  private var cache: CachedLibrarySnapshot?
  private var store: DraftStore?
  private var deleted: Set<String> = []
  private var published: [Gist] = []
  private var seededCopies = false
  private let metadataDelay: Duration
  private(set) var libraryReadCount = 0
  private(set) var metadataReadCount = 0
  private(set) var publicationReasons: [PublishReason] = []

  init(
    autosave: Bool = ProcessInfo.processInfo.arguments.contains("--capture-autosave"),
    metadataDelay: Duration = ProcessInfo.processInfo.arguments.contains("--capture-slow-publication-metadata")
      ? .seconds(30) : .zero
  ) {
    account = NotebookAccount(
      id: UUID(), login: "synthetic-notebook", githubUserID: 1,
      preferences: .init(isAutoSaveEnabled: autosave, accentColor: nil))
    self.metadataDelay = metadataDelay
  }

  func cachedAccount() -> NotebookAccount? { account }
  func signIn() -> NotebookAccount { account }
  func refreshAccount() -> NotebookAccount { account }
  func gists(accountID: UUID) throws -> [Gist] {
    libraryReadCount += 1
    return try fixtureGists(
      includeDeleted: ProcessInfo.processInfo.arguments.contains("--capture-stale-deletion")
    ).filter { $0.id != "shared" }
  }
  func starredGists(accountID: UUID) throws -> [Gist] {
    try fixtureGists().filter { $0.id == "shared" }
  }

  func gist(id: String, accountID: UUID) async throws -> Gist {
    metadataReadCount += 1
    if id == "newcapture" { try await Task.sleep(for: metadataDelay) }
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
  ) async throws -> DraftSnapshot {
    let store = try draftStore()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LibraryPublicationCaptureProtocol.self]
    let client = GitHubClient(session: URLSession(configuration: configuration)) { "synthetic" }
    let saved = try await SyncCoordinator(client: client, store: store, mutationInterval: .zero)
      .publish(
        id: draftID, accountID: accountID, reason: reason,
        expectedGeneration: expectedGeneration, shouldPublish: shouldPublish)
    publicationReasons.append(reason)
    cache = try await store.cachedLibrary(accountID: accountID)
    if let id = saved.gistID, let gist = cache?.details[id] { published = [gist] }
    return saved
  }

  func localState(accountID: UUID) async throws -> NotebookLocalState {
    if ProcessInfo.processInfo.arguments.contains("--capture-local-copies"), !seededCopies {
      seededCopies = true
      let store = try draftStore()
      let draft = try await store.openDraft(
        accountID: accountID, githubUserID: 1, gistID: "missing", filename: "README.md",
        description: "A local copy", content: "Published text", revision: "one")
      _ = try await store.persist(
        id: draft.id, accountID: accountID, text: "An unpublished thought to keep", generation: 1)
    }
    return .init(library: cache, drafts: try await store?.drafts(accountID: accountID) ?? [])
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) async throws {
    try await draftStore().cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id)
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
    if case .discardLocalCopy(let id, let generation) = action {
      try await draftStore().discardLocalCopy(
        id: id, accountID: accountID, expectedGeneration: generation)
      return .discardedDraft(id)
    }
    if case .discardCleanMissingCopy(let id, let generation, let shouldDiscard) = action {
      let store = try draftStore()
      let draft = try await store.draft(id: id, accountID: accountID)
      guard try fixtureGists().allSatisfy({ $0.id != draft.gistID }) else { return .review(draft) }
      guard await shouldDiscard() else { return .review(draft) }
      if try await store.discardLocalCopy(
        id: id, accountID: accountID, expectedGeneration: generation, onlyIfClean: true)
      {
        return .discardedDraft(id)
      }
      return .review(draft)
    }
    guard case .delete(let id) = action, id != "shared",
      try fixtureGists().contains(where: { $0.id == id })
    else { throw CaptureError.unsupported }
    deleted.insert(id)
    return .deleted(
      gistID: id,
      drafts: try await draftStore().removeDraftsForDeletedGist(
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
      + published.filter { !deleted.contains($0.id) }
  }

  private enum CaptureError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This synthetic fixture does not perform that account action." }
  }
}

/// Parks the synthetic create response so a test can act while the publication is in flight.
final class LibraryPublicationHold: @unchecked Sendable {
  static let shared = LibraryPublicationHold()

  private let lock = NSLock()
  private var isEnabled = false
  private var parkedDelivery: (() -> Void)?

  func enable() {
    lock.withLock { isEnabled = true }
  }

  func park(_ deliver: @escaping () -> Void) -> Bool {
    lock.withLock {
      guard isEnabled else { return false }
      parkedDelivery = deliver
      return true
    }
  }

  func waitUntilParked(timeout: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if lock.withLock({ parkedDelivery != nil }) { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  func release() {
    let delivery = lock.withLock { () -> (() -> Void)? in
      isEnabled = false
      let delivery = parkedDelivery
      parkedDelivery = nil
      return delivery
    }
    delivery?()
  }
}

private final class LibraryPublicationCaptureProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard request.httpMethod == "POST", let url = request.url, url.path == "/gists" else {
        throw URLError(.unsupportedURL)
      }
      var body = request.httpBody ?? Data()
      if body.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
          if count == 0 { break }
          body.append(contentsOf: buffer.prefix(count))
        }
      }
      guard let creation = try JSONSerialization.jsonObject(with: body) as? [String: Any],
        let files = creation["files"] as? [String: [String: Any]]
      else { throw URLError(.cannotDecodeRawData) }
      var responseFiles = files
      for (filename, file) in files {
        var response = file
        response["filename"] = filename
        response["language"] = "Markdown"
        responseFiles[filename] = response
      }
      let payload: [String: Any] = [
        "id": "newcapture", "description": creation["description"] ?? "",
        "public": false, "files": responseFiles,
        "updated_at": "2026-10-25T21:00:00Z", "created_at": "2026-10-25T21:00:00Z",
        "owner": ["id": 1, "login": "synthetic-notebook"],
        "history": [["version": "published"]],
      ]
      guard let response = HTTPURLResponse(
        url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
      else { throw URLError(.badServerResponse) }
      let body = try JSONSerialization.data(withJSONObject: payload)
      let deliver: () -> Void = {
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
      }
      if !LibraryPublicationHold.shared.park(deliver) { deliver() }
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}
#endif
