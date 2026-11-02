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
    let session = try await fixture.session()
    try await fixture.type(typed, in: session)
    await #expect(throws: PlatformError.staleTask) {
      try await fixture.bridge.setTask(id: stale.id, completed: true)
    }
    let kept = try await fixture.store.draft(id: session.draft.id, accountID: fixture.account.id)
    #expect(kept.text == typed)

    try await fixture.bridge.refresh()
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

  @Test func addToTodayLandsAfterTodaysPublishIsCutOffAndPublishesOnceOnline() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let session = try await fixture.session()
    let typed = session.editor.text + "- [ ] Written offline\n"
    try await fixture.type(typed, in: session)
    // Today's publish goes out and is cut off, so GitHub may or may not have it.
    fixture.fixture.fail("PATCH")
    await session.publish()
    #expect(try await fixture.store.draft(id: session.draft.id, accountID: fixture.account.id)
      .attemptedContent == typed)
    fixture.fixture.restore()

    try await fixture.bridge.addToToday(text: "A thought", asTask: true, target: DailyNote.Day())
    #expect(session.editor.text == typed + "- [ ] A thought\n")
    #expect(session.saveState == .savedLocally)
    #expect(fixture.publishes.isEmpty)

    await fixture.library.publishUnsyncedEdits()
    #expect(fixture.publishes == ["PATCH /gists/daily123"])
    #expect(fixture.fixture.remote("daily123", DailyNote.Day().filename) == session.editor.text)
    #expect(session.saveState == .savedToGitHub)
  }

  @Test func aPickedImageUploadsThenInsertsItsMarkdownAtTheCursorAsOneUndo() async throws {
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
    let url = try #require(URL(string: "https://example.com/assets/daily123/image.png"))
    var uploadedGistIDs: [String] = []
    let images = ImageUpload(session: session) { _, gistID in
      uploadedGistIDs.append(gistID)
      return url
    }
    images.chooseImage()
    #expect(images.isShowingPicker)
    session.editor.textView.selectedRange = NSRange(
      location: (original as NSString).length, length: 0)
    await images.add(image: Data("image".utf8))
    #expect(images.failure == nil && !images.isUploading)
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
    // Connected the way the app launches, so every file the library opens reaches the bridge.
    let sync = GitHubSync(accounts: fixture.accounts, drafts: fixture.store)
    let library = PlatformBridge.connect(sync, store: fixture.store, lastOpened: fixture.lastOpened)
    await library.start()
    let bridge = try #require(PlatformBridge.shared)
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

  /// Today, open as the app opens it at launch.
  func session() async throws -> FileSession {
    try #require(library.sessions[try await today().draft.id])
  }

  /// Typing in `session`, saved on this iPhone.
  func type(_ text: String, in session: FileSession) async throws {
    session.editor.textView.text = text
    session.editor.textViewDidChange(session.editor.textView)
    try #require(await session.waitForLocalSave())
  }

  func cleanUp() {
    try? LibrarySnapshot.make(accountID: nil, cache: nil, drafts: []).write()
  }
}
