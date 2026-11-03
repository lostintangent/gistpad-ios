import AppIntents
import Foundation
import Editor
import Interface
@testable import Platform
import SwiftUI
import Testing
import UIKit

@testable import GistPad
@testable import Sync

@Suite(.serialized)
@MainActor
struct PlatformTests {
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

  @Test func siriAppendPreservesFrontMatterAndUsesTheOpenEditorsDurableEdit() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let session = try await fixture.session()
    let snapshot = try #require(try LibrarySnapshot.read())
    let note = try #require(snapshot.gists.first {
      $0.link == GistPadLink.gist(id: "daily123", filename: nil)
    })
    let other = try #require(snapshot.gists.first {
      $0.link == GistPadLink.gist(id: "daily123", filename: "another.md")
    })
    #expect(other.content == nil)
    #expect(other.excerpt == nil)
    let closed = try #require(try await fixture.bridge.noteEntities(for: [other.id]).first)
    #expect(closed.content == nil)
    fixture.library.isForeground = true
    fixture.bridge.setVisibleNote(note.id, session: session)
    defer { fixture.bridge.setVisibleNote(nil, session: session) }
    let visible = try #require(try await fixture.bridge.noteEntities(for: [note.id]).first)
    #expect(String(try #require(visible.content).characters) == session.editor.text)
    #expect(visible.attributeSet.textContent == nil)
    let original = session.editor.text
    let intent = AppendToGistIntent()
    intent.dailyNotes = fixture.bridge
    intent.target = note
    intent.content = AttributedString("Pick up the dry cleaning")

    _ = try await intent.perform()

    #expect(session.editor.text == original + "Pick up the dry cleaning\n")
    #expect(await session.waitForLocalSave())
    #expect(fixture.publishes.isEmpty)
    #expect(try await fixture.store.draft(id: session.draft.id, accountID: fixture.account.id).text
      == session.editor.text)
  }

  @Test func siriAppendToAClosedFileKeepsItsFrontMatterAndDoesNotExposeTheBody() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let snapshot = try #require(try LibrarySnapshot.read())
    let note = try #require(snapshot.gists.first {
      $0.link == GistPadLink.gist(id: "daily123", filename: "another.md")
    })

    let updated = try await fixture.bridge.appendToNote(note, text: "A new line")

    #expect(updated.content == nil)
    let local = try await fixture.sync.localState(accountID: fixture.account.id)
    let draft = try #require(local.drafts.first { $0.filename == "another.md" })
    #expect(draft.text == "---\nsecret: hide this from Siri\n---\n\nAnother note\nA new line\n")
    #expect(fixture.publishes.isEmpty)
  }

  @Test func siriOnlyReadsTheVisibleEditorsLiveBodyWithoutFrontMatter() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let snapshot = try #require(try LibrarySnapshot.read())
    let note = try #require(snapshot.gists.first {
      $0.link == .gist(id: "daily123", filename: "another.md")
    })
    await fixture.library.open(.gist(id: "daily123", filename: "another.md"))
    let session = try #require(fixture.library.activeSession)
    fixture.library.isForeground = true
    fixture.bridge.setVisibleNote(note.id, session: session)
    defer { fixture.bridge.setVisibleNote(nil, session: session) }

    let open = try #require(try await fixture.bridge.noteEntities(for: [note.id]).first)
    #expect(String(try #require(open.content).characters) == "Another note\n")
    #expect(open.attributeSet.textContent == nil)
    session.editor.textView.text += "Vagabond is first.\n"
    session.editor.textViewDidChange(session.editor.textView)
    let typing = try #require(try await fixture.bridge.noteEntities(for: [note.id]).first)
    #expect(String(try #require(typing.content).characters)
      == "Another note\nVagabond is first.\n")

    fixture.library.isForeground = false
    #expect(try await fixture.bridge.noteEntities(for: [note.id]).first?.content == nil)
    fixture.library.isForeground = true
    fixture.bridge.setVisibleNote(nil, session: session)
    #expect(try await fixture.bridge.noteEntities(for: [note.id]).first?.content == nil)
  }

  @Test func returningToLibraryClearsTheEditorsOnscreenEntity() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    await fixture.library.open(.today())
    let session = try #require(fixture.library.activeSession)
    let note = try #require(try LibrarySnapshot.read()?.gists.first {
      $0.link == .gist(id: "daily123", filename: nil)
    })
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: RootView(library: fixture.library).environment(\.scenePhase, .active))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(500))
    #expect(scene.activationState == .foregroundActive)
    #expect(fixture.library.state.selectedID != nil)
    #expect(fixture.library.isForeground)
    #expect(session.editor.textView.window != nil)
    #expect(session.editor.textView.appEntityIdentifier?.identifier == note.id)

    fixture.library.showLibrary()
    try await Task.sleep(for: .milliseconds(500))
    #expect(session.editor.textView.appEntityIdentifier == nil)
    #expect(try await fixture.bridge.noteEntities(for: [note.id]).first?.content == nil)
  }

  @Test func siriUpdateRenamesTheOwnedGistThroughTheLibrary() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let snapshot = try #require(try LibrarySnapshot.read())
    let note = try #require(snapshot.gists.first {
      $0.link == GistPadLink.gist(id: "manga", filename: nil)
    })
    let intent = UpdateGistNoteIntent()
    intent.dailyNotes = fixture.bridge
    intent.target = note
    intent.name = AttributedString("Reading Library")

    _ = try await intent.perform()

    #expect(try await fixture.sync.localState(accountID: fixture.account.id)
      .cache?.owned.first(where: { $0.id == "manga" })?.description == "Reading Library")
    #expect(fixture.publishes == ["PATCH /gists/manga"])
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
          "another.md": "---\nsecret: hide this from Siri\n---\n\nAnother note\n",
        ])
      server.addGist(
        id: "manga", description: "Manga reading list",
        files: ["README.md": "# Ranked\n1. Vagabond\n"])
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
