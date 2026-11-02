import AppIntents
import Foundation
import GistPadEditor
import GistPadInterface
@testable import GistPadPlatform
import SwiftUI
import Testing
import UIKit

@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct PlatformTests {
  @Test
  func widgetToggleReachesTheOpenFileUndoesAsOneEditAndNeverOverwritesNewerTyping() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let stale = try #require(try LibrarySnapshot.read()?.today.tasks.first)
    let typed = "# Today\n\nStill typing\n- [ ] A real task\n"
    let draft = try await fixture.today().draft
    _ = try await fixture.store.persist(
      id: draft.id, accountID: fixture.account.id, text: typed, generation: draft.generation + 1)
    await #expect(throws: PlatformError.staleTask) {
      try await fixture.bridge.setTask(id: stale.id, completed: true)
    }
    let kept = try await fixture.store.draft(id: draft.id, accountID: fixture.account.id)
    #expect(kept.text == typed)

    try await fixture.bridge.refresh()
    let session = try await fixture.session()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: EditorView(editor: session.editor))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(100))
    let editor = session.editor.textView
    let task = try #require(try LibrarySnapshot.read()?.today.tasks.first)
    try await fixture.bridge.setTask(id: task.id, completed: true)
    #expect(session.editor.text == typed.replacingOccurrences(of: "[ ]", with: "[x]"))
    #expect(session.editor.textView === editor)
    session.editor.textView.undoManager?.undo()
    #expect(await session.waitForLocalSave())
    #expect(session.editor.text == typed)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func addToTodayFromAShortcutLandsInTodaysNoteWithoutASheetOrAPublish() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let session = try await fixture.session()
    let previousLink = PendingLink.shared.link
    let intent = AddToTodayIntent()
    intent.dailyNotes = fixture.bridge
    intent.text = "A thought\nSecond task"
    intent.asTask = true
    _ = try await intent.perform()
    #expect(
      session.editor.text.hasSuffix("- [ ] A real task\n- [ ] A thought\n- [ ] Second task\n"))
    #expect(
      try LibrarySnapshot.read()?.today.tasks.map(\.title)
        == ["A real task", "A thought", "Second task"])
    #expect(PendingLink.shared.link == previousLink)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aPickedPhotoUploadsThenInsertsItsMarkdownAtTheCursorAsOneUndo() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let session = try await fixture.session()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: EditorView(editor: session.editor))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(100))
    let original = session.editor.text
    let url = try #require(URL(string: "https://example.com/assets/daily123/photo.png"))
    var uploadedGistIDs: [String] = []
    let photos = PhotoUpload(
      session: session, defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
    ) { _, gistID in
      uploadedGistIDs.append(gistID)
      return url
    }
    photos.choosePhoto()
    #expect(photos.isShowingNotice && !photos.isShowingPicker)
    photos.acceptNotice()
    #expect(photos.isShowingPicker)
    session.editor.textView.selectedRange = NSRange(
      location: (original as NSString).length, length: 0)
    await photos.add(png: Data("png".utf8))
    #expect(photos.failure == nil && !photos.isUploading)
    #expect(uploadedGistIDs == ["daily123"])
    #expect(session.editor.text == original + "![Image](\(url.absoluteString))")
    session.editor.textView.undoManager?.undo()
    #expect(session.editor.text == original)
    #expect(await session.waitForLocalSave())
    #expect(fixture.publishes.isEmpty)
  }
}

/// Today's note in a daily gist on the fixture GitHub, open in a fixture connected to widgets,
/// Spotlight and Shortcuts.
@MainActor
private struct PlatformFixture {
  let fixture: LibraryFixture
  let sync: GitHubSync
  let library: Library
  let bridge: PlatformBridge

  static func make() async throws -> Self {
    let fixture = try await LibraryFixture { server in
      server.addGist(
        id: "daily123", description: DailyNote.gistDescription,
        files: [
          DailyNote.Day().filename: "# Today\n\n- [ ] A real task\n",
          "another.md": "Another note\n",
        ])
    }
    // The bridge and the fixture share one GitHubSync, as the app connects them at launch.
    let sync = GitHubSync(accounts: fixture.accounts, drafts: fixture.store)
    let library = Library(sync: sync, lastOpened: fixture.lastOpened)
    await library.start()
    let bridge = PlatformBridge(sync: sync, store: fixture.store, library: library)
    try await bridge.refresh()
    return Self(
      fixture: fixture, sync: sync, library: library, bridge: bridge)
  }

  var account: Account { fixture.account }
  var store: DraftStore { fixture.store }
  var publishes: [String] { fixture.publishes }

  func today() async throws -> (gist: Gist?, draft: Draft) {
    try await sync.today(accountID: account.id, target: DailyNote.Day())
  }

  func session() async throws -> FileSession {
    let today = try await today()
    let file = File(draft: today.draft, gist: today.gist)
    let session = FileSession(
      file: file, draft: today.draft, library: library)
    bridge.register(session)
    return session
  }

  func cleanUp() {
    try? LibrarySnapshot.make(accountID: nil, cache: nil, drafts: []).write()
  }
}
