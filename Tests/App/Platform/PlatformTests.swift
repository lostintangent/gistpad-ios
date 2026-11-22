import AppIntents
import Foundation
@testable import Editor
import Screens
@testable import Platform
import SwiftUI
import Testing
import UIKit

@testable import GistPad
@testable import Model
@testable import Store

@Suite(.serialized)
struct PlatformTests {
  @Test func addToTodayFromAShortcutAppendsToTodaysNoteWithoutASheetOrAPublish() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let fileEditor = try await fixture.fileEditor()
    let previousLink = PendingLink.shared.link
    let intent = AddToTodayIntent()
    intent.app = fixture.bridge
    intent.text = "A thought\nSecond task"
    intent.asTask = true
    _ = try await intent.perform()
    #expect(
      fileEditor.editor.text.hasSuffix("- [ ] A real task\n- [ ] A thought\n- [ ] Second task\n"))
    #expect(PendingLink.shared.link == previousLink)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func addToTodayAppendsAfterTodaysPublishIsCutOffAndPublishesOnceOnline() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let fileEditor = try await fixture.fileEditor()
    let typed = fileEditor.editor.text + "- [ ] Written offline\n"
    fileEditor.editor.textView.text = typed
    fileEditor.editor.textViewDidChange(fileEditor.editor.textView)
    try #require(await fileEditor.waitForLocalSave())
    // Today's publish goes out and is cut off, so GitHub may or may not have it.
    fixture.fixture.fail("PATCH")
    await fileEditor.publish()
    #expect(try await fixture.store.current(fileEditor.file.nextDraft)?.sent == typed)
    fixture.fixture.restore()

    try await fixture.bridge.addToToday(text: "A thought", asTask: true, target: DailyNote.Day())
    #expect(fileEditor.editor.text == typed + "- [ ] A thought\n")
    #expect(fileEditor.status == .unpublished)
    #expect(fixture.publishes.isEmpty)

    await fixture.model.publishDrafts()
    #expect(fixture.publishes == ["PATCH /gists/daily123"])
    #expect(fixture.fixture.onGitHub("daily123", DailyNote.Day().filename) == fileEditor.editor.text)
    #expect(fileEditor.status == .published)
  }

  @Test func siriCreatesANoteThroughANewGistDraftAndRejectsUnsupportedOptions() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let previousLink = PendingLink.shared.link
    defer { PendingLink.shared.link = previousLink }
    let intent = CreateGistNoteIntent()
    intent.app = fixture.bridge
    intent.name = AttributedString("Test Reading List")
    intent.content = AttributedString("# Ranked\n1. Vagabond\n")
    intent.attachments = []
    intent.isPinned = true
    await #expect(throws: PlatformError.unsupportedNoteCreation) {
      _ = try await intent.perform()
    }
    intent.isPinned = false
    intent.name = AttributedString("   ")
    await #expect(throws: PlatformError.emptyNoteName) {
      _ = try await intent.perform()
    }
    intent.name = AttributedString("Test Reading List")

    _ = try await intent.perform()

    let draft = try #require(fixture.model.drafts.first {
      $0.gistID == nil && $0.newGistName == "Test Reading List"
    })
    #expect(fixture.model.drafts.filter { $0.newGistName == "Test Reading List" }.count == 1)
    #expect(draft.text == "# Ranked\n1. Vagabond\n")
    let link = GistPadLink.unpublishedGist(accountID: fixture.account.id, draftID: draft.id)
    #expect(PendingLink.shared.link == link)
    let note = try #require(try LibrarySnapshot.read()?.gists.first { $0.link == link })
    #expect(note.content == nil)
    #expect(fixture.publishes.isEmpty)
    await fixture.model.open(.draft(id: draft.id))
    #expect(fixture.model.activeEditor?.file.id == draft.id)
  }

  @Test func siriAppendUsesTheOpenEditorsDurableEdit() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let fileEditor = try await fixture.fileEditor()
    let note = try #require(try LibrarySnapshot.read()?.gists.first {
      $0.link == GistPadLink.gist(id: "daily123", filename: nil)
    })
    let original = fileEditor.editor.text
    let intent = AppendToGistIntent()
    intent.app = fixture.bridge
    intent.target = note
    intent.content = AttributedString("Pick up the dry cleaning")

    _ = try await intent.perform()

    #expect(fileEditor.editor.text == original + "Pick up the dry cleaning\n")
    #expect(await fileEditor.waitForLocalSave())
    #expect(fixture.publishes.isEmpty)
    #expect(try await fixture.store.current(fileEditor.file.nextDraft)?.text == fileEditor.editor.text)
  }

  @Test func siriAppendToAClosedFileKeepsItsFrontMatterAndDoesNotExposeTheBody() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let snapshot = try #require(try LibrarySnapshot.read())
    let note = try #require(snapshot.gists.first {
      $0.link == GistPadLink.gist(id: "daily123", filename: "another.md")
    })
    // Opening Today read the whole gist, so its sibling's excerpt is known, without front matter.
    #expect(note.excerpt == "Another note")

    let updated = try await fixture.bridge.appendToNote(note, text: "A new line")

    #expect(updated.content == nil)
    let draft = try #require(fixture.model.drafts.first { $0.filename == "another.md" })
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
    await fixture.model.open(.gist(id: "daily123", filename: "another.md"))
    let fileEditor = try #require(fixture.model.activeEditor)
    fixture.model.isForeground = true
    fileEditor.editor.entityIdentifier = EntityIdentifier(for: GistEntity.self, identifier: note.id)
    defer { fileEditor.editor.entityIdentifier = nil }

    let open = try #require(try await fixture.bridge.noteEntities(for: [note.id]).first)
    #expect(String(try #require(open.content).characters) == "Another note\n")
    #expect(open.attributeSet.textContent == nil)
    fileEditor.editor.textView.text += "Vagabond is first.\n"
    fileEditor.editor.textViewDidChange(fileEditor.editor.textView)
    let typing = try #require(try await fixture.bridge.noteEntities(for: [note.id]).first)
    #expect(String(try #require(typing.content).characters)
      == "Another note\nVagabond is first.\n")

    fixture.model.isForeground = false
    #expect(try await fixture.bridge.noteEntities(for: [note.id]).first?.content == nil)
    fixture.model.isForeground = true
    fileEditor.editor.entityIdentifier = nil
    #expect(try await fixture.bridge.noteEntities(for: [note.id]).first?.content == nil)
  }

  @Test func returningToLibraryClearsTheEditorsOnscreenEntity() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    await fixture.model.open(.today())
    let fileEditor = try #require(fixture.model.activeEditor)
    let note = try #require(try LibrarySnapshot.read()?.gists.first {
      $0.link == .gist(id: "daily123", filename: nil)
    })
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: RootView(model: fixture.model).environment(\.scenePhase, .active))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(500))
    // Launch restores the account before it returns to the app.
    for _ in 0..<100 where !fixture.model.isForeground {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(scene.activationState == .foregroundActive)
    #expect(fixture.model.state.selectedID != nil)
    #expect(fixture.model.isForeground)
    #expect(fileEditor.editor.textView.window != nil)
    #expect(fileEditor.editor.textView.appEntityIdentifier?.identifier == note.id)

    fixture.model.showLibrary()
    try await Task.sleep(for: .milliseconds(500))
    #expect(fileEditor.editor.textView.appEntityIdentifier == nil)
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
    intent.app = fixture.bridge
    intent.target = note
    intent.name = AttributedString("Reading Library")

    _ = try await intent.perform()

    #expect(
      fixture.model.gistCache?.owned.first(where: { $0.id == "manga" })?.description
        == "Reading Library")
    #expect(fixture.publishes == ["PATCH /gists/manga"])
  }

  @Test func aPickedImageUploadsThenInsertsItsMarkdownAtTheCursorAsOneUndo() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let fileEditor = try await fixture.fileEditor()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: EditorView(editor: fileEditor.editor))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(100))
    let original = fileEditor.editor.text
    fixture.fixture.server.intercept { request in
      request.url?.path.hasPrefix("/storage/v1/object/assets/daily123/") == true ? .init() : nil
    }
    let images = ImageUpload(model: fixture.model)
    images.chooseImage(for: fileEditor)
    #expect(images.isShowingPicker)
    fileEditor.editor.textView.selectedRange = NSRange(
      location: (original as NSString).length, length: 0)
    await images.add(image: UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in })
    #expect(images.failure == nil && !images.isUploading)
    #expect(fileEditor.editor.text.hasPrefix(
      original + "![Image](\(GistPadAccountStore.projectURL)/storage/v1/object/public/assets/daily123/"))
    #expect(fileEditor.editor.text.hasSuffix(".png)"))
    fileEditor.editor.textView.undoManager?.undo()
    #expect(fileEditor.editor.text == original)
    #expect(await fileEditor.waitForLocalSave())
    #expect(fixture.publishes.isEmpty)
  }
}

/// Today's note in a daily gist on the fixture GitHub, open in a fixture connected to widgets,
/// Spotlight and Shortcuts.
private struct PlatformFixture {
  let fixture: ModelFixture
  let model: GistPadModel
  let bridge: PlatformBridge

  static func make() async throws -> Self {
    let fixture = try await ModelFixture { server in
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
    let model = PlatformBridge.connect(fixture.model)
    await model.start()
    await model.open(.today())
    let bridge = try #require(PlatformBridge.shared)
    try await bridge.refresh()
    return Self(fixture: fixture, model: model, bridge: bridge)
  }

  var account: GistPadAccount { fixture.account }
  var store: GistFileDraftStore { fixture.store }
  var publishes: [String] { fixture.publishes }

  /// Today, opened from the Today button.
  func fileEditor() async throws -> GistFileEditor {
    try #require(model.editors[try await model.today().id])
  }

  func cleanUp() {
    try? LibrarySnapshot.make(account: nil, cache: nil, drafts: []).write()
  }
}
