import Foundation
import GistPadSync
import Synchronization
import Testing

@testable import GistPad

/// The library the app ships (its account store, draft store and GitHubSync) signed in to
/// Sync's fixture GitHub, so tests drive real requests instead of a fake.
@MainActor
struct LibraryFixture {
  let server = FixtureServer()
  let accounts: AccountStore
  let store: DraftStore
  let lastOpened = LastOpened()
  let account: Account
  let library: Library

  /// Seeds GitHub, signs in and saves `preferences`, like a web account. Autosave is on unless
  /// `autosave` turns it off. A remembered `selection` reopens at launch instead of Today.
  init(
    autosave: Bool = true, preferences: [Preferences.Change] = [],
    selection: FileReference? = nil, seed: (FixtureServer) throws -> Void = { _ in }
  ) async throws {
    try seed(server)
    accounts = try server.accounts()
    var account = try await server.signIn(accounts)
    let operations = preferences + (autosave ? [] : [.setBoolean(.isAutoSaveEnabled, false)])
    if !operations.isEmpty { account = try await accounts.update(operations, accountID: account.id) }
    self.account = account
    store = try DraftStore.open(inMemory: true)
    if let selection { lastOpened.save(selection, accountID: account.id) }
    library = Library(
      sync: GitHubSync(accounts: accounts, drafts: store), lastOpened: lastOpened)
  }

  /// The app launching again on this iPhone, with the same drafts and remembered file.
  func relaunch() -> Library {
    Library(
      sync: GitHubSync(accounts: accounts, drafts: store), lastOpened: lastOpened)
  }

  /// Every publish so far: a new gist or an edit to one.
  var publishes: [String] {
    server.requests.filter { $0 == "POST /gists" || $0.hasPrefix("PATCH /gists/") }
  }

  /// A file's text on GitHub right now.
  func remote(_ gistID: String, _ filename: String) -> String? {
    server.gists.first { $0.id == gistID }?.files[filename]?.content
  }

  /// A local edit made before this launch, of a gist that's on GitHub or that used to be.
  func stageEdit(gistID: String, filename: String, text: String) async throws -> Draft {
    let gist = server.gists.first { $0.id == gistID }
    let draft = try await store.draft(
      accountID: account.id, githubUserID: FixtureServer.you.id, gistID: gistID,
      filename: filename, description: gist?.description ?? "",
      content: gist?.files[filename]?.content ?? "", revision: gist?.revision,
      isNewFile: gist != nil && gist?.files[filename] == nil)
    return try await store.persist(
      id: draft.id, accountID: account.id, text: text, generation: draft.generation + 1)
  }

  /// Fails every request whose "METHOD /path" starts with `prefix`, as if offline.
  func fail(_ prefix: String = "") {
    server.intercept { request in
      if Self.line(request).hasPrefix(prefix) { throw URLError(.notConnectedToInternet) }
      return nil
    }
  }

  /// Holds every request whose "METHOD /path" starts with `prefix` until the gate opens.
  func hold(_ prefix: String) -> Gate {
    let gate = Gate()
    server.intercept { request in
      guard Self.line(request).hasPrefix(prefix) else { return nil }
      await gate.pass()
      return nil
    }
    return gate
  }

  /// Answers the next sign-in as a different Supabase user and GitHub account.
  func signInNext(as id: UUID, login: String) throws {
    let user: [String: Any] = [
      "id": id.uuidString, "aud": "authenticated", "created_at": "2026-10-23T20:00:00Z",
      "updated_at": "2026-10-23T20:00:00Z", "app_metadata": ["provider": "github"],
      "user_metadata": ["user_name": login, "sub": String(FixtureServer.someoneElse.id)],
    ]
    let token = try JSONSerialization.data(withJSONObject: [
      "access_token": "other-access", "refresh_token": "other-refresh", "token_type": "bearer",
      "expires_in": 3600, "expires_at": 4_102_444_800, "provider_token": "other-github",
      "user": user,
    ])
    let profile = try JSONSerialization.data(withJSONObject: user)
    server.intercept { request in
      let headers = ["Content-Type": "application/json"]
      switch Self.line(request) {
      case "POST /auth/v1/token": return .init(headers: headers, data: token)
      case "GET /auth/v1/user": return .init(headers: headers, data: profile)
      default: return nil
      }
    }
  }

  /// Answers every request normally again.
  func restore() {
    server.intercept(nil)
  }

  private nonisolated static func line(_ request: URLRequest) -> String {
    "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
  }

  /// A held request, released when the test opens it.
  final class Gate: Sendable {
    private let state = Mutex((arrived: false, isOpen: false))

    /// Waits until a held request arrives.
    func arrival() async throws {
      while !state.withLock({ $0.arrived }) { try await Task.sleep(for: .milliseconds(5)) }
    }

    func open() {
      state.withLock { $0.isOpen = true }
    }

    fileprivate func pass() async {
      state.withLock { $0.arrived = true }
      while !state.withLock({ $0.isOpen }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
  }
}
