import Editor
import Foundation
import Interface
import Sync
import Testing

@testable import Notebook

/// The app on one iPhone, signed in to the fixture GitHub. It launches, opens, types and leaves
/// the way RootView drives the library, and reads what you'd see on screen and on GitHub.
@MainActor
final class Phone {
  let fixture: LibraryFixture
  private(set) var library: Library

  init(
    autosave: Bool = true, preferences: [Preferences.Change] = [], lastFile: FileReference? = nil,
    github seed: (FixtureServer) throws -> Void = { _ in }
  ) async throws {
    fixture = try await LibraryFixture(
      autosave: autosave, preferences: preferences, selection: lastFile, seed: seed)
    library = fixture.library
  }

  var github: FixtureServer { fixture.server }
  var accountID: UUID { fixture.account.id }

  // MARK: Coming and going

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

  func goOffline() { fixture.fail() }
  func goOnline() { fixture.restore() }

  /// Every request fails with `code`, like a connection that drops.
  func dropRequests(_ code: URLError.Code) { fixture.fail(with: code) }

  // MARK: Writing

  /// Opens a file and leaves the one it replaces, as RootView does.
  @discardableResult
  func open(_ request: Opening.Request) async throws -> FileSession {
    let previous = library.activeSession
    await library.open(request)
    let session = try #require(library.activeSession)
    if let previous, previous !== session { await previous.leave() }
    return session
  }

  /// Taps a row in the list.
  @discardableResult
  func open(row id: String) async throws -> FileSession {
    await library.openRow(id: id)
    return try #require(library.activeSession)
  }

  /// Types over the file's text, one edit after another.
  func type(_ texts: String..., in session: FileSession) async throws {
    let editor = session.editor
    for text in texts {
      let whole = NSRange(location: 0, length: editor.text.utf16.count)
      try editor.apply(
        Edit(range: whole, expected: editor.text, replacement: text), generation: editor.generation)
    }
    try #require(await session.waitForLocalSave())
  }

  /// Goes back to the list.
  func leave(_ session: FileSession) async {
    library.showLibrary()
    await session.leave()
  }

  /// An edit from before this launch that never published.
  @discardableResult
  func leftover(_ gistID: String, _ filename: String = "README.md", text: String) async throws
    -> Draft
  {
    try await fixture.stageEdit(gistID: gistID, filename: filename, text: text)
  }

  // MARK: Changing gists

  /// What deleting a row would remove, as its confirmation asks.
  func deletion(row id: String) throws -> Change {
    try #require(library.deletion(forRow: id))
  }

  func delete(_ deletion: Change) async throws {
    _ = try await library.apply(deletion, accountID: accountID)
  }

  /// Deletes a row from the list, as its swipe action does.
  func delete(row id: String) async throws {
    try await delete(deletion(row: id))
  }

  func name(_ session: FileSession, _ title: String) async throws {
    _ = try await library.apply(.renameLocal(session.draft, title: title), accountID: accountID)
  }

  func rename(_ gistID: String, to title: String) async throws {
    _ = try await library.apply(.rename(gistID: gistID, title: title), accountID: accountID)
  }

  func rename(_ gistID: String, _ filename: String, to newFilename: String) async throws {
    _ = try await library.apply(
      .renameFile(gistID: gistID, filename: filename, newFilename: newFilename),
      accountID: accountID)
  }

  func add(_ filename: String, to gistID: String) async throws {
    _ = try await library.apply(.addFile(gistID: gistID, filename: filename), accountID: accountID)
  }

  func star(_ gistID: String) async throws {
    _ = try await library.apply(.star(gistID: gistID, starred: true), accountID: accountID)
  }

  func pin(_ gistID: String) async throws {
    _ = try await library.apply(
      .preferences([.setPinned(gistID: gistID, pinned: true)]), accountID: accountID)
  }

  func signOut() async throws {
    _ = try await library.apply(.signOut, accountID: accountID)
  }

  // MARK: The web

  func webEdits(_ gistID: String, _ files: [String: String?]) {
    github.edit(gistID, files: files)
  }

  func webDeletes(_ gistID: String) async throws {
    var request = URLRequest(url: URL(string: "https://api.github.com/gists/\(gistID)")!)
    request.httpMethod = "DELETE"
    _ = try await github.session.data(for: request)
  }

  // MARK: What you see

  /// The text in the editor, or nil with nothing open.
  var onScreen: String? { library.activeSession?.editor.text }

  /// The gist rows in the list, without daily notes.
  var rows: [GistItem] { library.state.gists.filter { !$0.isDailyNote } }

  func row(_ id: String) -> GistItem? { library.state.gists.first { $0.id == id } }

  /// The daily note rows in the list.
  var days: Set<String> { Set(library.state.gists.filter(\.isDailyNote).map(\.id)) }

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

  /// Every publish so far: a new gist or an edit to one.
  var publishes: [String] { fixture.publishes }
}
