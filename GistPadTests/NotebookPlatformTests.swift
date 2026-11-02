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
  @Test func widgetToggleReachesTheOpenFileUndoesAsOneEditAndNeverOverwritesNewerTyping() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let stale = try #require(try fixture.shared.read()?.today.tasks.first)
    let typed = "# Today\n\nStill typing\n- [ ] A real task\n"
    let draft = try await fixture.today()
    _ = try await fixture.store.persist(
      id: draft.id, accountID: fixture.account.id, text: typed, generation: 1)
    await #expect(throws: NotebookPlatformError.staleTask) {
      try await fixture.bridge.setTask(id: stale.id, completed: true)
    }
    #expect(try await fixture.store.draft(id: draft.id, accountID: fixture.account.id).text == typed)

    try await fixture.bridge.refresh()
    let controller = try await fixture.controller()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: MarkdownEditorView(session: controller.session))
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
    #expect(await fixture.provider.publishCount == 0)
  }

  @Test func addToTodayFromAShortcutLandsInTodaysNoteWithoutASheetOrAPublish() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let controller = try await fixture.controller()
    let previousRoute = NotebookRouteInbox.shared.pending
    var intent = AddToTodayIntent()
    intent.notebook = fixture.bridge
    intent.text = "A thought\nSecond task"
    intent.asTask = true
    _ = try await intent.perform()
    #expect(controller.session.text.hasSuffix("- [ ] A real task\n- [ ] A thought\n- [ ] Second task\n"))
    #expect(try fixture.shared.read()?.today.tasks.map(\.title) == ["A real task", "A thought", "Second task"])
    #expect(NotebookRouteInbox.shared.pending == previousRoute)
    #expect(await fixture.provider.publishCount == 0)
  }

  @Test func aPickedPhotoUploadsThenInsertsItsMarkdownAtTheCursorAsOneUndo() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let controller = try await fixture.controller()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: MarkdownEditorView(session: controller.session))
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
    photos.noticeDidDismiss()
    #expect(photos.isShowingPicker)
    controller.session.textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
    await photos.add(png: Data("png".utf8))
    #expect(photos.failure == nil && !photos.isUploading)
    #expect(uploadedGistIDs == ["daily123"])
    #expect(controller.session.text == original + "![Image](\(url.absoluteString))")
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == original)
    #expect(await controller.waitForLocalSave())
    #expect(await fixture.provider.publishCount == 0)
  }
}

@MainActor
private struct PlatformFixture {
  let account: Account
  let provider: PlatformNotebookProvider
  let store: DraftStore
  let model: NotebookModel
  let bridge: NotebookPlatformBridge
  let shared: SharedNotebookStore

  static func make() async throws -> Self {
    let account = Account(
      id: UUID(), login: "synthetic", githubUserID: 42, preferences: .init(metadata: [:]))
    let filename = DailyNoteTarget().filename
    let payload: [String: Any] = [
      "id": "daily123", "description": GistConventions.dailyNotesDescription,
      "public": false, "owner": ["id": 42, "login": "synthetic"],
      "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-24T00:00:00Z",
      "files": [
        filename: ["filename": filename, "language": "Markdown", "content": "# Today\n\n- [ ] A real task\n"],
        "another.md": ["filename": "another.md", "language": "Markdown", "content": "Another note\n"]
      ],
      "history": [["version": "1"]]
    ]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let gist = try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: payload))
    let store = try DraftStore.open(inMemory: true)
    let provider = PlatformNotebookProvider(account: account, gist: gist, store: store)
    let model = NotebookModel(provider: provider)
    await model.start()
    let bridge = NotebookPlatformBridge(provider: provider, store: store, notebook: model)
    try await bridge.refresh()
    return Self(
      account: account, provider: provider, store: store, model: model, bridge: bridge,
      shared: try SharedNotebookStore())
  }

  func today() async throws -> DraftSnapshot {
    try await provider.today(accountID: account.id, target: DailyNoteTarget()).draft
  }

  func controller() async throws -> NotebookSessionController {
    let draft = try await today()
    let document = NotebookDocument(draft: draft, gist: provider.gist)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    bridge.register(controller)
    return controller
  }

  func cleanUp() {
    try? shared.write(.make(accountID: nil, cache: nil, drafts: []))
  }
}

private actor PlatformNotebookProvider: NotebookProviding {
  var account: Account
  let gist: Gist
  let store: DraftStore
  private(set) var publishCount = 0

  init(account: Account, gist: Gist, store: DraftStore) {
    self.account = account
    self.gist = gist
    self.store = store
  }

  func cachedAccount() -> Account? { account }
  func refreshAccount() -> Account { account }
  func signIn() -> Account { account }
  func gists(accountID: UUID) -> [Gist] { [gist] }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) -> Gist { gist }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    guard let text = gist.files[filename]?.content else { throw GitHubClientError.missingFile }
    return text
  }
  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    try await store.openDraft(
      accountID: account.id, githubUserID: 42, gistID: gist.id, filename: document.filename,
      description: gist.description ?? "", content: document.text, revision: gist.revision)
  }
  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws -> DraftSnapshot {
    try await store.persist(id: draftID, accountID: accountID, text: text, generation: generation)
  }
  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason, expectedGeneration: UInt64?,
    shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> DraftSnapshot {
    publishCount += 1
    return try await store.draft(id: draftID, accountID: accountID)
  }
  func localState(accountID: UUID) async throws -> NotebookLocalState {
    NotebookLocalState(
      library: try await store.cachedLibrary(accountID: accountID),
      drafts: try await store.drafts(accountID: accountID))
  }
  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account, keeping: Set<String>) async throws {
    try await store.cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id,
      keeping: keeping)
  }
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    TodayNote(gist: gist, draft: try await store.openDraft(
      accountID: accountID, githubUserID: 42, gistID: gist.id, filename: target.filename,
      description: gist.description ?? "", content: gist.files[target.filename]?.content ?? "",
      revision: gist.revision))
  }
  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    throw CocoaError(.featureUnsupported)
  }
  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await store.discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    throw CocoaError(.featureUnsupported)
  }
}
