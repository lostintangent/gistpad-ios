import Foundation
import Sync

/// GitHub, the account and the drafts on this iPhone, behind one actor the library talks to.
actor GitHubSync {
  let accounts: AccountStore
  let drafts: DraftStore
  let mutationQueue = SerialQueue()
  private var clients: [UUID: GitHubClient] = [:]
  private var publishers: [UUID: DraftPublisher] = [:]
  private var dailyServices: [UUID: DailyNotes] = [:]

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

  func draft(for file: File) async throws -> Draft {
    guard let gist = file.gist else { throw GitHubClientError.missingFile }
    let githubUserID = try await verifiedUserID(accountID: file.accountID)
    return try await drafts.draft(
      accountID: file.accountID, githubUserID: githubUserID,
      gistID: gist.id, filename: file.filename,
      description: gist.description ?? "",
      content: file.text, revision: gist.revision)
  }

  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> Draft
  {
    try await drafts.persist(id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> Draft {
    let publisher = await publisher(accountID: accountID)
    return try await mutationQueue.run {
      try await publisher.publish(
        id: draftID, accountID: accountID, reason: reason,
        expectedGeneration: expectedGeneration, shouldPublish: shouldPublish)
    }
  }

  func localState(accountID: UUID) async throws -> LocalState {
    let cache = try await drafts.cachedLibrary(accountID: accountID)
    let localDrafts = try await drafts.drafts(accountID: accountID)
    return LocalState(cache: cache, drafts: localDrafts)
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account, keeping: Set<String> = [])
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

  func createDraft(
    accountID: UUID, description: String = "", content: String? = nil
  ) async throws -> Draft {
    let userID = try await verifiedUserID(accountID: accountID)
    return try await drafts.newGistDraft(
      accountID: accountID, githubUserID: userID, description: description, content: content)
  }

  func discardBlankDraft(_ draft: Draft) async throws -> Bool {
    try await drafts.discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }

  func today(accountID: UUID, target: DailyNote.Day) async throws -> (gist: Gist?, draft: Draft) {
    let service: DailyNotes
    if let existing = dailyServices[accountID] {
      service = existing
    } else {
      let userID = try await verifiedUserID(accountID: accountID)
      let client = await client(accountID: accountID)
      let publisher = await publisher(accountID: accountID)
      service =
        dailyServices[accountID]
        ?? DailyNotes(
          accountID: accountID, githubUserID: userID, client: client,
          store: drafts, publisher: publisher)
      dailyServices[accountID] = service
    }
    return try await mutationQueue.run { try await service.stageToday(target: target) }
  }

  private func publisher(accountID: UUID) async -> DraftPublisher {
    if let publisher = publishers[accountID] { return publisher }
    let client = await client(accountID: accountID)
    if let existing = publishers[accountID] { return existing }
    let publisher = DraftPublisher(client: client, store: drafts)
    publishers[accountID] = publisher
    return publisher
  }
}
