import Editor
import Foundation
import Screens
import Store
import Testing

@testable import Model

/// The app on one iPhone, signed in to the fixture GitHub. It launches, opens, types and leaves
/// the way RootView drives the library, and reads what you'd see on screen and on GitHub.
@MainActor
final class Phone {
  let fixture: ModelFixture
  private(set) var model: GistPadModel

  init(
    autosave: Bool = true, preferences: [GistPadPreferences.Change] = [], lastFile: Opening.Request? = nil,
    github seed: (FixtureServer) throws -> Void = { _ in }
  ) async throws {
    fixture = try await ModelFixture(
      autosave: autosave, preferences: preferences, lastOpened: lastFile, seed: seed)
    model = fixture.model
  }

  var github: FixtureServer { fixture.server }
  var accountID: UUID { fixture.account.id }

  // MARK: Coming and going

  func launch() async {
    await model.start()
    await model.returnToApp()
  }

  /// The app quitting and launching again, with the same files on this iPhone.
  func relaunch() async {
    model = fixture.relaunch()
    await launch()
  }

  func leaveApp() async {
    await model.leaveApp()
  }

  func returnToApp() async {
    await model.returnToApp()
  }

  func goOffline() { fixture.fail() }
  func goOnline() { fixture.restore() }

  /// Every request fails with `code`, like a connection that drops.
  func dropRequests(_ code: URLError.Code) { fixture.fail(with: code) }

  // MARK: Writing

  /// Opens a file and leaves the one it replaces, as RootView does.
  @discardableResult
  func open(_ request: Opening.Request) async throws -> GistFileEditor {
    let previous = model.activeEditor
    await model.open(request)
    let fileEditor = try #require(model.activeEditor)
    if let previous, previous !== fileEditor { await previous.leave() }
    return fileEditor
  }

  /// Taps a row in the list.
  @discardableResult
  func open(row id: String) async throws -> GistFileEditor {
    await model.open(model.request(forRow: id))
    return try #require(model.activeEditor)
  }

  /// Types over the file's text, one edit after another.
  func type(_ texts: String..., in fileEditor: GistFileEditor) async throws {
    let editor = fileEditor.editor
    for text in texts {
      let whole = NSRange(location: 0, length: editor.text.utf16.count)
      try editor.apply(
        Edit(range: whole, expected: editor.text, replacement: text), generation: editor.generation)
    }
    try #require(await fileEditor.waitForLocalSave())
  }

  /// Goes back to the list.
  func leave(_ fileEditor: GistFileEditor) async {
    model.showLibrary()
    await fileEditor.leave()
  }

  /// An edit from before this launch that never published.
  @discardableResult
  func leftover(_ gistID: String, _ filename: String = "README.md", text: String) async throws
    -> GistFileDraft
  {
    try await fixture.stageEdit(gistID: gistID, filename: filename, text: text)
  }

  // MARK: Changing gists

  /// What deleting a row would remove, as its confirmation asks.
  func deletion(row id: String) throws -> Deletion {
    try #require(model.deletion(forRow: id))
  }

  func delete(_ deletion: Deletion) async throws {
    try await model.delete(deletion)
  }

  /// Deletes a row from the list, as its swipe action does.
  func delete(row id: String) async throws {
    try await delete(deletion(row: id))
  }

  func name(_ fileEditor: GistFileEditor, _ title: String) async throws {
    try await model.rename(fileEditor.file.nextDraft, to: title)
  }

  func rename(_ gistID: String, to title: String) async throws {
    try await model.rename(GistFileDraft(accountID: accountID, gistID: gistID), to: title)
  }

  func rename(_ gistID: String, _ filename: String, to newFilename: String) async throws {
    try await model.renameFile(
      GistFileDraft(accountID: accountID, gistID: gistID, filename: filename), to: newFilename)
  }

  func add(_ filename: String, to gistID: String) async throws {
    try await model.addFile(named: filename, to: gistID)
  }

  func star(_ gistID: String) async throws {
    try await model.setStarred(true, gistID: gistID)
  }

  func pin(_ gistID: String) async throws {
    try await model.updatePreferences([.setPinned(gistID: gistID, pinned: true)])
  }

  func signOut() async throws {
    try await model.signOut()
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
  var onScreen: String? { model.activeEditor?.editor.text }

  /// The gist rows in the list, without daily notes.
  var rows: [GistItem] { model.state.gists.filter { !$0.isDailyNote } }

  func row(_ id: String) -> GistItem? { model.state.gists.first { $0.id == id } }

  /// The daily note rows in the list.
  var days: Set<String> { Set(model.state.gists.filter(\.isDailyNote).map(\.id)) }

  /// The list's GitHub status: a problem's heading, "Checking" while it refreshes, or nil.
  var status: String? {
    switch model.remoteRefreshStatus {
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
