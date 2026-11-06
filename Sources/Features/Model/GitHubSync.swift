import Comments
import Foundation
import Store

/// GitHub, the account and the drafts on this iPhone, behind one actor the library talks to.
public actor GitHubSync {
  let accounts: AccountStore
  let drafts: DraftStore
  private let queue = SerialQueue()
  private var clients: [UUID: GitHubClient] = [:]

  public init(accounts: AccountStore, drafts: DraftStore) {
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

  public func cachedAccount() async throws -> GistPadAccount? {
    try await accounts.cachedAccount()
  }

  public func connectedAccount() async throws -> GistPadAccount? {
    try await accounts.connectedAccount()
  }

  func signIn() async throws -> GistPadAccount {
    try await accounts.signIn()
  }

  func refreshAccount() async throws -> GistPadAccount {
    try await accounts.refreshAccount()
  }

  public func gists(accountID: UUID) async throws -> [Gist] {
    let client = await client(accountID: accountID)
    return try await client.listGists()
  }

  public func starredGists(accountID: UUID) async throws -> [Gist] {
    let client = await client(accountID: accountID)
    return try await client.listStarredGists()
  }

  func gist(id: String, accountID: UUID) async throws -> Gist {
    let client = await client(accountID: accountID)
    let gist = try await client.gist(id: id)
    try await drafts.cacheGist(gist, accountID: accountID)
    return gist
  }

  public func content(gist: Gist, filename: String, accountID: UUID) async throws -> String {
    let client = await client(accountID: accountID)
    let text = try await client.content(gist: gist, filename: filename)
    try await drafts.cacheContent(text, gist: gist, filename: filename, accountID: accountID)
    return text
  }

  func current(_ draft: Draft) async throws -> Draft {
    try await drafts.current(draft)
  }

  func save(_ draft: Draft, text: String, generation: UInt64) async throws -> Draft {
    try await drafts.save(draft, text: text, generation: generation)
  }

  func keep(_ draft: Draft) async throws -> Draft {
    try await drafts.keep(draft)
  }

  func publish(_ draft: Draft) async throws -> Draft {
    let publisher = await publisher(accountID: draft.accountID)
    return try await serially { _ in try await publisher.publish(draft) }
  }

  /// Runs one change to GitHub or the drafts at a time, so a publish, a new day and a rename never
  /// interleave.
  func serially<Value: Sendable>(
    _ operation: @Sendable (GitHubSync) async throws -> Value
  ) async throws -> Value {
    try await queue.run { try await operation(self) }
  }

  public func localState(accountID: UUID) async throws -> LocalState {
    let cache = try await drafts.gistCache(accountID: accountID)
    let localDrafts = try await drafts.drafts(accountID: accountID)
    return LocalState(cache: cache, drafts: localDrafts)
  }

  public func cacheGists(owned: [Gist], starred: [Gist], accountID: UUID) async throws {
    try await drafts.cacheGists(owned: owned, starred: starred, accountID: accountID)
  }

  public func verifiedUserID(accountID: UUID) async throws -> Int64 {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    guard let id = account.githubUserID else { throw AccountError.reconnectGitHub }
    return id
  }

  /// Stores a new gist you've named, or one made from outside the app, before you type in it.
  public func createDraft(
    accountID: UUID, description: String, content: String? = nil
  ) async throws -> Draft {
    let userID = try await verifiedUserID(accountID: accountID)
    return try await drafts.keep(
      Draft(accountID: accountID, githubUserID: userID, description: description, content: content))
  }

  public func today(accountID: UUID, target: DailyNote.Day) async throws -> (gist: Gist?, draft: Draft) {
    let userID = try await verifiedUserID(accountID: accountID)
    let service = DailyNotes(
      accountID: accountID, githubUserID: userID, client: await client(accountID: accountID),
      store: drafts)
    return try await serially { _ in try await service.stageToday(target: target) }
  }

  func uploadImage(_ image: Data, gistID: String, accountID: UUID) async throws -> URL {
    let storage = try await accounts.imageStorage(accountID: accountID)
    return try await storage.upload(image, gistID: gistID)
  }

  func comments(accountID: UUID) async throws -> CommentServices {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    let client = await client(accountID: accountID)
    let userID: Int64
    if let cachedID = account.githubUserID {
      userID = cachedID
    } else {
      userID = try await client.authenticatedUser().id
    }
    return CommentServices(remote: client, userID: userID)
  }

  private func publisher(accountID: UUID) async -> DraftPublisher {
    DraftPublisher(client: await client(accountID: accountID), store: drafts)
  }
}

public struct CommentServices: Sendable {
  public let remote: any CommentsRemote
  public let userID: Int64
}

public struct LocalState: Sendable {
  public let cache: GistCache?
  public let drafts: [Draft]
}

actor SerialQueue {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    if busy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      busy = true
    }
    defer {
      if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    try Task.checkCancellation()
    return try await operation()
  }
}
