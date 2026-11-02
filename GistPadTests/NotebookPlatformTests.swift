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
struct NotebookPlatformTests {
  @Test
  func widgetToggleReachesTheOpenFileUndoesAsOneEditAndNeverOverwritesNewerTyping() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let stale = try #require(try fixture.shared.read()?.today.tasks.first)
    let typed = "# Today\n\nStill typing\n- [ ] A real task\n"
    let draft = try await fixture.today().draft
    _ = try await fixture.store.persist(
      id: draft.id, accountID: fixture.account.id, text: typed, generation: draft.generation + 1)
    await #expect(throws: NotebookPlatformError.staleTask) {
      try await fixture.bridge.setTask(id: stale.id, completed: true)
    }
    let kept = try await fixture.store.draft(id: draft.id, accountID: fixture.account.id)
    #expect(kept.text == typed)

    try await fixture.bridge.refresh()
    let controller = try await fixture.controller()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: EditorView(session: controller.session))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(100))
    let editor = controller.session.textView
    let task = try #require(try fixture.shared.read()?.today.tasks.first)
    try await fixture.bridge.setTask(id: task.id, completed: true)
    #expect(controller.session.text == typed.replacingOccurrences(of: "[ ]", with: "[x]"))
    #expect(controller.session.textView === editor)
    controller.session.textView.undoManager?.undo()
    #expect(await controller.waitForLocalSave())
    #expect(controller.session.text == typed)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func addToTodayFromAShortcutLandsInTodaysNoteWithoutASheetOrAPublish() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let controller = try await fixture.controller()
    let previousRoute = NotebookRouteInbox.shared.pending
    let intent = AddToTodayIntent()
    intent.notebook = fixture.bridge
    intent.text = "A thought\nSecond task"
    intent.asTask = true
    _ = try await intent.perform()
    #expect(
      controller.session.text.hasSuffix("- [ ] A real task\n- [ ] A thought\n- [ ] Second task\n"))
    #expect(
      try fixture.shared.read()?.today.tasks.map(\.title)
        == ["A real task", "A thought", "Second task"])
    #expect(NotebookRouteInbox.shared.pending == previousRoute)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aPickedPhotoUploadsThenInsertsItsMarkdownAtTheCursorAsOneUndo() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let controller = try await fixture.controller()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: EditorView(session: controller.session))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(100))
    let original = controller.session.text
    let url = try #require(URL(string: "https://example.com/assets/daily123/photo.png"))
    var uploadedGistIDs: [String] = []
    let photos = NotebookPhotoController(
      note: controller, defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
    ) { _, gistID in
      uploadedGistIDs.append(gistID)
      return url
    }
    photos.choosePhoto()
    #expect(photos.isShowingNotice && !photos.isShowingPicker)
    photos.acceptNotice()
    #expect(photos.isShowingPicker)
    controller.session.textView.selectedRange = NSRange(
      location: (original as NSString).length, length: 0)
    await photos.add(png: Data("png".utf8))
    #expect(photos.failure == nil && !photos.isUploading)
    #expect(uploadedGistIDs == ["daily123"])
    #expect(controller.session.text == original + "![Image](\(url.absoluteString))")
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == original)
    #expect(await controller.waitForLocalSave())
    #expect(fixture.publishes.isEmpty)
  }
}

/// Today's note in a daily gist on the fixture GitHub, open in a notebook connected to widgets,
/// Spotlight and Shortcuts.
@MainActor
private struct PlatformFixture {
  let notebook: NotebookFixture
  let provider: LiveNotebookProvider
  let model: NotebookModel
  let bridge: NotebookPlatformBridge
  let shared: SharedNotebookStore

  static func make() async throws -> Self {
    let notebook = try await NotebookFixture { server in
      server.addGist(
        id: "daily123", description: DailyNote.gistDescription,
        files: [
          DailyNote.Day().filename: "# Today\n\n- [ ] A real task\n",
          "another.md": "Another note\n",
        ])
    }
    // The bridge and the notebook share one provider, as the app connects them at launch.
    let provider = LiveNotebookProvider(accounts: notebook.accounts, drafts: notebook.store)
    let model = NotebookModel(provider: provider, selections: notebook.selections)
    await model.start()
    let bridge = NotebookPlatformBridge(provider: provider, store: notebook.store, notebook: model)
    try await bridge.refresh()
    return Self(
      notebook: notebook, provider: provider, model: model, bridge: bridge,
      shared: try SharedNotebookStore())
  }

  var account: Account { notebook.account }
  var store: DraftStore { notebook.store }
  var publishes: [String] { notebook.publishes }

  func today() async throws -> (gist: Gist?, draft: Draft) {
    try await provider.today(accountID: account.id, target: DailyNote.Day())
  }

  func controller() async throws -> NotebookSessionController {
    let today = try await today()
    let document = NotebookDocument(draft: today.draft, gist: today.gist)
    let controller = NotebookSessionController(
      document: document, draft: today.draft, notebook: model)
    bridge.register(controller)
    return controller
  }

  func cleanUp() {
    try? shared.write(.make(accountID: nil, cache: nil, drafts: []))
  }
}
