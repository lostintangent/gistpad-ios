#if DEBUG
  import Foundation
  import Store
  import Synchronization

  /// The model the app ships, with its account and draft stores, signed in to Store's fixture
  /// GitHub, so tests drive real requests instead of a fake.
  @MainActor
  struct ModelFixture {
    let server = FixtureServer()
    let accounts: GistPadAccountStore
    let store: GistFileDraftStore
    /// This iPhone's remembered files, kept in memory so tests never share or leave one.
    let defaults: UserDefaults = MemoryDefaults()
    let account: GistPadAccount
    let model: GistPadModel

    /// Seeds GitHub, signs in and saves `preferences`, like a web account. Autosave is on unless
    /// `autosave` turns it off. The `lastOpened` file reopens at launch.
    init(
      autosave: Bool = true, preferences: [GistPadPreferences.Change] = [],
      lastOpened: Opening.Request? = nil, seed: (FixtureServer) throws -> Void = { _ in }
    ) async throws {
      try seed(server)
      accounts = try server.accounts()
      var account = try await server.signIn(accounts)
      let operations = preferences + (autosave ? [] : [.setBoolean(.isAutoSaveEnabled, false)])
      if !operations.isEmpty { account = try await accounts.update(operations, accountID: account.id) }
      self.account = account
      store = try GistFileDraftStore.open(inMemory: true)
      if let lastOpened {
        defaults.set(
          try JSONEncoder().encode(lastOpened), forKey: GistPadModel.lastOpenedKey(account.id))
      }
      model = GistPadModel(accounts: accounts, drafts: store, defaults: defaults)
    }

    /// The app launching again on this iPhone, with the same drafts and remembered file.
    func relaunch() -> GistPadModel {
      GistPadModel(accounts: accounts, drafts: store, defaults: defaults)
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
    func stageEdit(gistID: String, filename: String, text: String) async throws -> GistFileDraft {
      let gist = server.gists.first { $0.id == gistID }
      let content = gist?.files[filename]?.content
      let draft = GistFileDraft(
        accountID: account.id, gistID: gistID, filename: filename, text: content ?? "",
        base: gist == nil
          ? GitHubVersion(text: "", revision: nil)
          : content.map { GitHubVersion(text: $0, revision: gist?.revision) })
      return try await store.save(draft, text: text, github: nil)
    }

    /// Fails every request whose "METHOD /path" starts with `prefix`, as if offline unless `code`
    /// says otherwise.
    func fail(_ prefix: String = "", with code: URLError.Code = .notConnectedToInternet) {
      server.intercept { request in
        if Self.line(request).hasPrefix(prefix) { throw URLError(code) }
        return nil
      }
    }

    /// The next publish reaches GitHub, but its answer never comes back.
    func cutOffNextPublish() {
      let session = server.session
      let isFirst = Mutex(true)
      server.intercept { request in
        guard request.httpMethod == "POST" || request.httpMethod == "PATCH",
          isFirst.withLock({ first in
            defer { first = false }
            return first
          })
        else { return nil }
        _ = try await session.data(for: request)
        throw URLError(.networkConnectionLost)
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

  /// The few defaults the model reads and writes, without a suite on disk.
  private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
  }
#endif
