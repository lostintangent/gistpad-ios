import Editor
import Foundation
import Interface
import Sync
import Synchronization
import Testing
import UIKit

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

  /// Fails every request whose "METHOD /path" starts with `prefix`, as if offline unless `code`
  /// says otherwise.
  func fail(_ prefix: String = "", with code: URLError.Code = .notConnectedToInternet) {
    server.intercept { request in
      if Self.line(request).hasPrefix(prefix) { throw URLError(code) }
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

/// The app on one iPhone, signed in to the fixture GitHub. It launches, opens, types and leaves
/// the way RootView drives the library, and reads what you'd see on screen and on GitHub.
@MainActor
final class Phone {
  let fixture: LibraryFixture
  private(set) var library: Library

  init(
    autosave: Bool = true, lastFile: FileReference? = nil,
    github seed: (FixtureServer) throws -> Void = { _ in }
  ) async throws {
    fixture = try await LibraryFixture(autosave: autosave, selection: lastFile, seed: seed)
    library = fixture.library
  }

  var github: FixtureServer { fixture.server }
  var accountID: UUID { fixture.account.id }

  func launch() async {
    library.isForeground = true
    await library.start()
    await library.publishDrafts()
  }

  /// The app quitting and launching again, with the same files on this iPhone.
  func relaunch() async {
    library.isForeground = false
    library = fixture.relaunch()
    await launch()
  }

  /// Opens a file and leaves the one it replaces, as RootView does.
  @discardableResult
  func open(_ request: Opening.Request) async throws -> FileSession {
    let previous = library.activeSession
    await library.open(request)
    let session = try #require(library.activeSession)
    if let previous, previous !== session { await previous.leave() }
    return session
  }

  /// Types over the file's text, one edit after another.
  func type(_ texts: String..., in session: FileSession) async throws {
    for text in texts {
      session.editor.textView.text = text
      session.editor.textViewDidChange(session.editor.textView)
    }
    try #require(await session.waitForLocalSave())
  }

  /// Goes back to the list.
  func leave(_ session: FileSession) async {
    library.showLibrary()
    await session.leave()
  }

  func leaveApp() async {
    library.isForeground = false
    await FileSession.publishOnBackground(Array(library.sessions.values), shouldContinue: { true })
  }

  func returnToApp() async {
    library.isForeground = true
    await library.publishDrafts()
    await library.refreshOnReturn()
    library.updateCalendar()
    await library.activeSession?.inspectRemoteChanges()
  }

  /// Deletes a row from the list, as its swipe action does.
  func delete(row id: String) async throws {
    _ = try await library.apply(try #require(library.deletion(forRow: id)), accountID: accountID)
  }

  func goOffline() { fixture.fail() }
  func goOnline() { fixture.restore() }

  /// Every request fails with `code`, like a connection that drops.
  func dropRequests(_ code: URLError.Code) { fixture.fail(with: code) }

  /// An edit from before this launch that never published.
  func leftover(_ gistID: String, _ filename: String = "README.md", text: String) async throws {
    _ = try await fixture.stageEdit(gistID: gistID, filename: filename, text: text)
  }

  func webEdits(_ gistID: String, _ files: [String: String?]) {
    github.edit(gistID, files: files)
  }

  func webDeletes(_ gistID: String) async throws {
    var request = URLRequest(url: URL(string: "https://api.github.com/gists/\(gistID)")!)
    request.httpMethod = "DELETE"
    _ = try await github.session.data(for: request)
  }

  /// The text in the editor, or nil with nothing open.
  var onScreen: String? { library.activeSession?.editor.text }

  /// The gist rows in the list, without daily notes.
  var rows: [GistItem] { library.state.gists.filter { !$0.isDailyNote } }

  /// The daily note rows in the list.
  var days: [String] { library.state.gists.filter(\.isDailyNote).map(\.id) }

  /// The list's GitHub status: a problem's heading, "Checking" while it refreshes, or nil.
  var status: String? {
    switch library.remoteRefreshStatus {
    case .idle: nil
    case .checking: "Checking"
    case .problem(let problem): problem.heading
    }
  }

  func onGitHub(_ gistID: String, _ filename: String = "README.md") -> String? {
    fixture.remote(gistID, filename)
  }

  var publishes: [String] { fixture.publishes }
}
