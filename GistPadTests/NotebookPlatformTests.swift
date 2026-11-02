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
  @Test func widgetTaskUpdatesTheRetainedEditorAndUndoesAsOneEdit() async throws {
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
    let identity = controller.session.textView
    controller.session.textView.selectedRange = NSRange(location: 0, length: 0)
    let task = try #require(try fixture.shared.read()?.today.tasks.first)
    try await fixture.bridge.setTask(id: task.id, completed: true)
    #expect(controller.session.text == original.replacingOccurrences(of: "[ ]", with: "[x]"))
    #expect(controller.session.textView === identity)
    #expect(controller.session.generation == 1)
    #expect(await fixture.provider.publishCount == 0)
    controller.session.textView.undoManager?.undo()
    #expect(await controller.waitForLocalSave())
    #expect(controller.session.text == original)
    #expect(controller.session.generation == 2)
    #expect(try await fixture.store.draft(id: controller.draft.id, accountID: fixture.account.id).text == original)
  }

  @Test func staleWidgetTaskCannotModifyNewerSource() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let task = try #require(try fixture.shared.read()?.today.tasks.first)
    let changed = try await fixture.store.persist(
      id: task.draftID, accountID: fixture.account.id, text: "Newer source", generation: 1)
    await #expect(throws: DraftError.staleGeneration) {
      try await fixture.bridge.setTask(id: task.id, completed: true)
    }
    #expect(try await fixture.store.draft(id: task.draftID, accountID: fixture.account.id) == changed)
  }

  @Test func writingToolsAndAccountChangesRejectWidgetMutations() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let controller = try await fixture.controller()
    let task = try #require(try fixture.shared.read()?.today.tasks.first)
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    await #expect(throws: NotebookPlatformError.editingInProgress) {
      try await fixture.bridge.setTask(id: task.id, completed: true)
    }
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    await fixture.provider.changeAccount()
    await #expect(throws: NotebookPlatformError.accountChanged) {
      try await fixture.bridge.setTask(id: task.id, completed: true)
    }
    #expect(try await fixture.store.draft(id: task.draftID, accountID: fixture.account.id).generation == 0)
  }

  @Test func quickCaptureAppendsToPinnedDateAndDoesNotPublishWhileForeground() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let controller = try await fixture.controller()
    let target = DailyNoteTarget()
    try await fixture.bridge.addToToday(text: "A thought\nSecond task", asTask: true, target: target)
    #expect(controller.session.text.hasSuffix("- [ ] A thought\n- [ ] Second task\n"))
    #expect(await fixture.provider.targets == [target])
    #expect(await fixture.provider.publishCount == 0)
    #expect(try fixture.shared.read()?.today.tasks.count == 3)
  }

  @Test func captureReturnsTheExactPinnedDraftAndCachesItsEditableMetadata() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let target = DailyNoteTarget(date: .now.addingTimeInterval(-86_400))
    let draft = try await fixture.store.newFileDraft(
      accountID: fixture.account.id, githubUserID: 42, gistID: fixture.provider.gist.id,
      filename: target.filename, description: GistConventions.dailyNotesDescription,
      text: "# Pinned day\n")
    try await fixture.store.cacheLibrary(
      owned: [], starred: [], preferences: fixture.account.preferences,
      accountID: fixture.account.id)
    try await fixture.model.reloadPlatformState(accountID: fixture.account.id)
    let destination = try await fixture.bridge.addToToday(
      text: "A late thought", asTask: false, target: target)
    #expect(destination == .draft(accountID: fixture.account.id, draftID: draft.id))
    await fixture.model.openLocalDraft(id: draft.id)
    let document = try #require(fixture.model.loadedDocument)
    #expect(document.filename == target.filename)
    #expect(document.gist?.id == fixture.provider.gist.id)
    #expect(!document.isRecovery)
    #expect(document.text.hasSuffix("A late thought\n"))
    #expect(document.chrome.access.canEdit)
    #expect(await fixture.provider.publishCount == 0)
  }

  @Test func capturedUnopenedNoteJoinsTheExistingForegroundAutosave() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    await fixture.model.open(gistID: fixture.provider.gist.id, filename: "another.md")
    #expect(fixture.model.loadedDocument?.filename == "another.md")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let routes = NotebookRouteInbox()
    let window = UIWindow(windowScene: scene)
    window.frame = scene.effectiveGeometry.coordinateSpace.bounds
    window.rootViewController = UIHostingController(
      rootView: LiveNotebookWorkspace(notebook: fixture.model, routes: routes)
        .environment(\.scenePhase, .active))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let destination = try await fixture.bridge.addToToday(
      text: "A captured thought", asTask: false, target: DailyNoteTarget())
    #expect(await fixture.provider.publishCount == 0)
    routes.submit(destination)
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while await fixture.provider.publishCount == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(fixture.model.loadedDocument?.text.hasSuffix("A captured thought\n") == true)
    #expect(routes.pending == nil)
    let publishCount = await fixture.provider.publishCount
    #expect(publishCount == 1)
  }

  @Test func intentsUseTheOfficialMainProcessExecutionTarget() {
    #expect(SetTodayTaskIntent.allowedExecutionTargets == .main)
    #expect(AddToTodayIntent.allowedExecutionTargets == .main)
    #expect(CaptureTodayIntent.allowedExecutionTargets == .main)
    #expect(NoteEntityQuery.allowedExecutionTargets == .main)
    #expect(SetTodayTaskIntent.authenticationPolicy == .requiresAuthentication)
  }

  @Test func providedShortcutTextAndWidgetIntentReachTheDurableOwnerWithoutASheet() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    NotebookIntentRuntime.configure { fixture.bridge }
    defer { NotebookPlatformBootstrap.install() }
    let previousRoute = NotebookRouteInbox.shared.pending?.id
    _ = try await AddToTodayIntent(text: "One captured task", asTask: true).perform()
    let snapshot = try #require(try fixture.shared.read())
    #expect(snapshot.today.tasks.map(\.title) == ["A real task", "One captured task"])
    #expect(await fixture.provider.targets.count == 1)
    let task = try #require(snapshot.today.tasks.first)
    _ = try await SetTodayTaskIntent(task: task, completed: true).perform()
    let draft = try await fixture.store.draft(id: task.draftID, accountID: fixture.account.id)
    #expect(draft.generation == 2)
    #expect(draft.text.contains("- [x] A real task"))
    #expect(NotebookRouteInbox.shared.pending?.id == previousRoute)
    #expect(await fixture.provider.publishCount == 0)
  }

  @Test func widgetSnapshotReopensWithDeviceProtectionWhenAvailable() async throws {
    let fixture = try await PlatformFixture.make()
    defer { fixture.cleanUp() }
    let url = fixture.shared.location.directory.appendingPathComponent("notebook.snapshot")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect(try SharedNotebookStore(location: fixture.shared.location).read() == fixture.shared.read())
    #if !targetEnvironment(simulator)
    #expect(attributes[.protectionKey] as? String == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    #endif
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
  let directory: URL

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
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let shared = SharedNotebookStore(location: try SharedStoreLocation(containerURL: directory))
    let bridge = NotebookPlatformBridge(
      provider: provider, store: store, notebook: model, sharedStore: shared, isBackgrounded: { false })
    try await bridge.refresh()
    return Self(
      account: account, provider: provider, store: store, model: model, bridge: bridge,
      shared: shared, directory: directory)
  }

  func controller() async throws -> NotebookSessionController {
    let draft = try #require(try await store.drafts(accountID: account.id).first)
    let document = NotebookDocument(draft: draft, gist: provider.gist)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    bridge.register(controller)
    return controller
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private actor PlatformNotebookProvider: NotebookProviding {
  var account: Account
  let gist: Gist
  let store: DraftStore
  private(set) var publishCount = 0
  private(set) var targets: [DailyNoteTarget] = []

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
  func cacheLibrary(owned: [Gist], starred: [Gist], account: Account) async throws {
    try await store.cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id)
  }
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    targets.append(target)
    let draft = try #require(try await store.drafts(accountID: accountID).first { $0.filename == target.filename })
    return TodayNote(target: target, gist: gist, draft: draft)
  }
  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    throw NotebookPlatformError.serviceUnavailable
  }
  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await store.discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    throw NotebookPlatformError.serviceUnavailable
  }
  func changeAccount() {
    account = Account(id: UUID(), login: "other", githubUserID: 99, preferences: .init(metadata: [:]))
  }
}
