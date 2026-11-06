import Foundation
import Sync

/// GitHub, the account and the drafts on this iPhone, behind one actor the library talks to.
actor GitHubSync {
  let accounts: AccountStore
  let drafts: DraftStore
  let mutationQueue = SerialQueue()
  private var clients: [UUID: GitHubClient] = [:]

  init(accounts: AccountStore, drafts: DraftStore) {
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
    return try await mutationQueue.run { try await publisher.publish(draft) }
  }

  func localState(accountID: UUID) async throws -> LocalState {
    let cache = try await drafts.cachedLibrary(accountID: accountID)
    let localDrafts = try await drafts.drafts(accountID: accountID)
    return LocalState(cache: cache, drafts: localDrafts)
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account) async throws {
    try await drafts.cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id)
  }

  func verifiedUserID(accountID: UUID) async throws -> Int64 {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    guard let id = account.githubUserID else { throw AccountError.reconnectGitHub }
    return id
  }

  /// Stores a new gist you've named, or one made from outside the app, before you type in it.
  func createDraft(
    accountID: UUID, description: String, content: String? = nil
  ) async throws -> Draft {
    let userID = try await verifiedUserID(accountID: accountID)
    return try await drafts.keep(
      Draft(accountID: accountID, githubUserID: userID, description: description, content: content))
  }

  func today(accountID: UUID, target: DailyNote.Day) async throws -> (gist: Gist?, draft: Draft) {
    let userID = try await verifiedUserID(accountID: accountID)
    let service = DailyNotes(
      accountID: accountID, githubUserID: userID, client: await client(accountID: accountID),
      store: drafts)
    return try await mutationQueue.run { try await service.stageToday(target: target) }
  }

  private func publisher(accountID: UUID) async -> DraftPublisher {
    DraftPublisher(client: await client(accountID: accountID), store: drafts)
  }
}
