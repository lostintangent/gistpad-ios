import Foundation
import GistPadEditor
import GistPadInterface
import SwiftUI
import Testing
import UIKit

@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct NotebookSessionTests {
  @Test func productionFocusArrangementRetainsTheEditorSelectionAndUndo() async throws {
    let (controller, _) = try await makeController()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(
      rootView: FocusNoteFixture(controller: controller, focused: false))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(200))
    let view = controller.session.textView
    view.becomeFirstResponder()
    view.selectedRange = NSRange(location: 2, length: 0)
    view.undoManager?.beginUndoGrouping()
    view.insertText("日本語 👩🏽‍💻")
    view.undoManager?.endUndoGrouping()
    let text = view.text
    let selection = view.selectedRange
    for focused in [true, false, true, false] {
      host.rootView = FocusNoteFixture(controller: controller, focused: focused)
      try await Task.sleep(for: .milliseconds(100))
      host.view.layoutIfNeeded()
      #expect(controller.session.textView === view)
      #expect(view.window === window)
      #expect(view.text == text)
      #expect(view.selectedRange == selection)
    }
    view.undoManager?.undo()
    #expect(view.text == "Base")
  }

  @Test func retainedRemoteChangeIsReviewedWithoutReplacingSourceSelectionOrUndo() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    let identity = controller.session.viewIdentity
    edit(controller, to: "Retained local draft")
    controller.session.textView.selectedRange = NSRange(location: 4, length: 3)
    #expect(await controller.waitForLocalSave())
    await provider.setRemoteContent("Changed in the web app")
    await controller.inspectRemoteChanges()
    #expect(controller.session.viewIdentity == identity)
    #expect(controller.session.text == "Retained local draft")
    #expect(controller.session.textView.selectedRange == NSRange(location: 4, length: 3))
    #expect(controller.saveState == .remoteChange)
    let review = try controller.reviewContext()
    #expect(review.conflict.remote == "Changed in the web app")
    #expect(controller.updateAutosave(isForeground: true) == nil)
    #expect(await provider.publishCount == 0)
    edit(controller, to: "Typing continues safely")
    #expect(await controller.waitForLocalSave())
    #expect(controller.saveState == .remoteChange)
  }

  @Test func autosavePublishesOnlyADurableQuietForegroundGeneration() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "Quiet accepted draft")
    #expect(await controller.waitForLocalSave())
    let task = try #require(controller.updateAutosave(isForeground: true))
    await task.value
    #expect(await provider.publishCount == 1)
    #expect(await provider.publicationReasons == [.autosave])
    #expect(controller.saveState == .savedToGitHub)
  }

  @Test func autosaveOffAndBackgroundNeverStartPublication() async throws {
    let (disabled, disabledProvider) = try await makeController(autosave: false)
    edit(disabled, to: "Keep local")
    #expect(await disabled.waitForLocalSave())
    #expect(disabled.updateAutosave(isForeground: true) == nil)
    #expect(disabled.updateAutosave(isForeground: false) == nil)
    #expect(await disabledProvider.publishCount == 0)

    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "Background local draft")
    #expect(await controller.waitForLocalSave())
    let pending = try #require(controller.updateAutosave(isForeground: true))
    #expect(controller.updateAutosave(isForeground: false) == nil)
    await pending.value
    #expect(await provider.publishCount == 0)
    #expect(try await provider.snapshot().text == "Background local draft")
  }

  @Test func autosaveDefersCompositionWritingToolsAndRecovery() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "Accepted text")
    #expect(await controller.waitForLocalSave())
    controller.session.textView.setMarkedText(
      "にほんご", selectedRange: NSRange(location: 4, length: 0))
    controller.session.textViewDidChangeSelection(controller.session.textView)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    controller.session.textView.unmarkText()
    controller.session.textViewDidChangeSelection(controller.session.textView)
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    controller.markRecovery()
    #expect(controller.updateAutosave(isForeground: true) == nil)
    #expect(await provider.publishCount == 0)
  }

  @Test func autosaveCancelsAnOlderPauseAndPublishesOnlyTheLatestText() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "First draft")
    #expect(await controller.waitForLocalSave())
    let old = try #require(controller.updateAutosave(isForeground: true))
    edit(controller, to: "Latest draft")
    #expect(await controller.waitForLocalSave())
    let latest = try #require(controller.updateAutosave(isForeground: true))
    await old.value
    await latest.value
    #expect(await provider.publishCount == 1)
    #expect(try await provider.snapshot().baseContent == "Latest draft")
  }

  @Test func restoredGenerationsAndRapidEditsPersistInOrder() async throws {
    let (controller, provider) = try await makeController(generation: 7)
    #expect(controller.session.generation == 7)
    for text in ["First", "Second", "日本語 👨‍👩‍👧‍👦"] { edit(controller, to: text) }
    #expect(await controller.waitForLocalSave())
    let saved = try await provider.snapshot()
    #expect(saved.generation == 10)
    #expect(saved.text.utf8.elementsEqual("日本語 👨‍👩‍👧‍👦".utf8))
    #expect(await provider.persistedGenerations == [8, 9, 10])
    #expect(controller.saveState == .savedLocally)
  }

  @Test func aPublishResponseCannotReplaceNewerTyping() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "The manually saved generation")
    #expect(await controller.waitForLocalSave())
    let publishing = Task { await controller.publish() }
    await provider.waitForPublish()
    edit(controller, to: "Newer typing stays local")
    #expect(await controller.waitForLocalSave())
    await provider.releasePublish()
    await publishing.value
    #expect(controller.session.text == "Newer typing stays local")
    #expect(controller.draft.text == "Newer typing stays local")
    #expect(controller.draft.baseContent == "The manually saved generation")
    #expect(controller.saveState == .savedLocally)
  }

  @Test func aLocalWriteFailureBlocksPublishing() async throws {
    let (controller, provider) = try await makeController()
    await provider.failPersistence()
    edit(controller, to: "Keep this in the editor")
    #expect(!(await controller.waitForLocalSave()))
    await controller.publish()
    #expect(await provider.publishCount == 0)
    #expect(controller.session.text == "Keep this in the editor")
    guard case .localFailure = controller.saveState else {
      Issue.record("An unacknowledged local write must remain an explicit failure.")
      return
    }
  }

  @Test func writingToolsPersistsOnlyTheFinalChoiceAndNeverPublishesPreviews() async throws {
    let (controller, provider) = try await makeController(generation: 7)
    let source = controller.session.text
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    edit(controller, to: "Temporary rewrite")
    #expect(controller.session.text == source)
    #expect(await provider.persistedGenerations.isEmpty)
    await controller.publish()
    #expect(await provider.publishCount == 0)
    edit(controller, to: "The accepted rewrite 日本語 👩🏽‍💻")
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    #expect(await provider.persistedGenerations == [8])
    #expect(try await provider.snapshot().text == "The accepted rewrite 日本語 👩🏽‍💻")
    #expect(controller.saveState == .savedLocally)
    #expect(await provider.publishCount == 0)

    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    edit(controller, to: "A rejected rewrite")
    edit(controller, to: "The accepted rewrite 日本語 👩🏽‍💻")
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    #expect(await provider.persistedGenerations == [8])
  }

  @Test func lostOwnershipBlocksFurtherPublication() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "A local edit")
    #expect(await controller.waitForLocalSave())
    await provider.rejectPublication()
    await controller.publish()
    guard case .publicationBlocked = controller.saveState else {
      Issue.record("Lost ownership must not become a retryable network failure.")
      return
    }
    #expect(!controller.saveState.canPublish)
  }

  @Test func durableInsertionIsOneNativeUndoAndNeverPublishes() async throws {
    let (controller, provider) = try await makeController()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let identity = ObjectIdentifier(controller.session.textView)
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(
        location: 4, length: 0, expectedText: "",
        replacement: "\n![Image](https://example.test/image.png)"))
    try await controller.applyDurableEdit(command) {
      try await provider.store.apply(command)
    }
    #expect(controller.session.text == "Base\n![Image](https://example.test/image.png)")
    #expect(controller.session.generation == 1)
    #expect(ObjectIdentifier(controller.session.textView) == identity)
    #expect(controller.session.textView.undoManager?.canUndo == true)
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == "Base")
    #expect(await controller.waitForLocalSave())
    #expect(try await provider.snapshot().text == "Base")
    #expect(await provider.publishCount == 0)
  }

  @Test func aFailedDurableCommitLeavesSourceSelectionAndGenerationUntouched() async throws {
    let (controller, _) = try await makeController()
    controller.session.textView.selectedRange = NSRange(location: 2, length: 1)
    let selection = controller.session.textView.selectedRange
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(location: 4, length: 0, expectedText: "", replacement: " changed"))
    await #expect(throws: URLError.self) {
      try await controller.applyDurableEdit(command) { throw URLError(.cannotWriteToFile) }
    }
    #expect(controller.session.text == "Base")
    #expect(controller.session.generation == 0)
    #expect(controller.session.textView.selectedRange == selection)
    #expect(controller.session.textView.isEditable)
  }

  @Test func staleDurableCommandsCannotReplaceNewerTyping() async throws {
    let (controller, provider) = try await makeController()
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(location: 4, length: 0, expectedText: "", replacement: " changed"))
    edit(controller, to: "Newer 日本語")
    #expect(await controller.waitForLocalSave())
    await #expect(throws: DraftError.staleGeneration) {
      try await controller.applyDurableEdit(command) {
        try await provider.store.apply(command)
      }
    }
    #expect(controller.session.text == "Newer 日本語")
    #expect(try await provider.snapshot().text == "Newer 日本語")
  }

  @Test func recoveryEditsStayLocalAndCannotRecreateADeletedGist() async throws {
    let (controller, provider) = try await makeController()
    controller.markRecovery()
    edit(controller, to: "A recoverable local edit")
    #expect(await controller.waitForLocalSave())
    #expect(!controller.saveState.canPublish)
    await controller.publish()
    #expect(await provider.publishCount == 0)
    #expect(try await provider.snapshot().text == "A recoverable local edit")
  }

  @Test func destructiveActionsLockInputUntilLocalPersistenceFinishes() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "Finish this local generation first")
    try controller.beginDestructiveAction()
    #expect(!controller.session.textView.isEditable)
    #expect(!controller.canMutate)
    #expect(await controller.waitForLocalSave())
    #expect(try await provider.snapshot().text == "Finish this local generation first")
    controller.endDestructiveAction()
    #expect(controller.session.textView.isEditable)
    #expect(controller.canMutate)
  }

  @Test func publishedLinksUseGistPadsShareRouteAndKeepLocalChangesSeparate() async throws {
    let (controller, _) = try await makeController()
    let links = try #require(try controller.savedLinks())
    #expect(links.shareURL.absoluteString == "https://gistpad.dev/#/share/synthetic/README.md")
    #expect(links.githubURL.absoluteString == "https://gist.github.com/synthetic")
    #expect(links.isSecret)
    #expect(!controller.hasUnpublishedChanges)
    edit(controller, to: "Not published")
    #expect(controller.hasUnpublishedChanges)
    #expect(await controller.waitForLocalSave())
    #expect(try controller.savedLinks()?.hasUnpublishedChanges == true)
  }

  @Test func sourceDiffsDistinguishUnicodeNormalizationAndMissingFiles() {
    let lines = NotebookDiffLine.changes(from: "cafe\u{301}", to: "caf\u{e9}")
    #expect(lines.count == 2)
    #expect(lines[0].isAddition == false)
    #expect(lines[0].text.utf8.elementsEqual("cafe\u{301}".utf8))
    #expect(lines[1].isAddition)
    let missing = NotebookDiffLine.changes(from: nil, to: "A newly created file")
    #expect(missing.count == 1)
    #expect(missing[0].isAddition)
  }

  @Test func keepingMyReviewedDraftDoesNotCreateAFakeGenerationOrUndo() async throws {
    let (controller, provider) = try await makeController(generation: 1, autosave: true)
    #expect(controller.document.chrome.isAutoSaveEnabled)
    _ = try await provider.introduceConflict(remote: "From GitHub")
    try await controller.refreshMetadata()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let undo = try #require(controller.session.textView.undoManager)
    undo.removeAllActions()
    let original = controller.session.text
    try await controller.commitMutation(
      .init(
        range: NSRange(location: 0, length: original.utf16.count), expected: original,
        replacement: original),
      expectedGeneration: 1
    ) {
      try await provider.store.resolveConflict(
        id: controller.draft.id, accountID: controller.draft.accountID,
        expectedGeneration: 1, text: original, generation: 1)
    }
    #expect(controller.session.generation == 1)
    #expect(!undo.canUndo)
    #expect(controller.saveState == .savedLocally)
    #expect(!controller.document.chrome.isAutoSaveEnabled)
    #expect(controller.saveState.canPublish)
    #expect(
      try await provider.store.recoveries(
        id: controller.draft.id, accountID: controller.draft.accountID
      ).count == 1)
    #expect(await provider.publishCount == 0)
  }

  @Test func adoptingAReviewedVersionIsOneRecoverableLocalUndo() async throws {
    let (controller, provider) = try await makeController(generation: 1, autosave: true)
    #expect(controller.document.chrome.isAutoSaveEnabled)
    _ = try await provider.introduceConflict(remote: "From GitHub 日本語")
    try await controller.refreshMetadata()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let original = controller.session.text
    try await controller.commitMutation(
      .init(
        range: NSRange(location: 0, length: original.utf16.count), expected: original,
        replacement: "From GitHub 日本語"),
      expectedGeneration: 1
    ) {
      try await provider.store.resolveConflict(
        id: controller.draft.id, accountID: controller.draft.accountID,
        expectedGeneration: 1, text: "From GitHub 日本語", generation: 2)
    }
    #expect(controller.session.text == "From GitHub 日本語")
    #expect(controller.saveState == .savedLocally)
    #expect(!controller.document.chrome.isAutoSaveEnabled)
    #expect(controller.saveState.canPublish)
    #expect(await provider.publishCount == 0)
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == original)
    #expect(await controller.waitForLocalSave())
    #expect(try await provider.snapshot().text == original)
  }

  @Test func staleReviewCannotOverwriteNewerSource() async throws {
    let (controller, provider) = try await makeController(generation: 1)
    _ = try await provider.introduceConflict(remote: "From GitHub")
    try await controller.refreshMetadata()
    let old = try controller.reviewContext()
    edit(controller, to: "A newer local choice")
    #expect(await controller.waitForLocalSave())
    #expect(!old.matches(controller.draft))
    await #expect(throws: NotebookActionError.staleReview) {
      try await controller.applyReview(old, text: "From GitHub")
    }
    #expect(controller.session.text == "A newer local choice")
    #expect(controller.draft.state != .savedToGitHub)
    #expect(await provider.publishCount == 0)
  }

  @Test func persistedPublicationUncertaintyIsNotLostToAGenericNetworkError() async throws {
    let (controller, provider) = try await makeController(generation: 1)
    await provider.failPublication(with: .failed(.publicationUncertain))
    await controller.publish()
    #expect(controller.saveState == .publicationUncertain)
    #expect(controller.draft.state == .failed(.publicationUncertain))
    #expect(!controller.saveState.canPublish)
  }

  @Test func writingToolsBlocksDurableInsertionsBeforeTheirCommit() async throws {
    let (controller, provider) = try await makeController()
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    defer { controller.session.textViewWritingToolsDidEnd(controller.session.textView) }
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(location: 4, length: 0, expectedText: "", replacement: " image"))
    await #expect(throws: SourceMutation.MutationError.compositionActive) {
      try await controller.applyDurableEdit(command) { try await provider.store.apply(command) }
    }
    #expect(controller.session.text == "Base")
    #expect(try await provider.snapshot().generation == 0)
  }

  private func edit(_ controller: NotebookSessionController, to text: String) {
    controller.session.textView.text = text
    controller.session.textViewDidChange(controller.session.textView)
  }

  private func makeController(
    generation: UInt64 = 0, autosave: Bool? = nil
  ) async throws -> (NotebookSessionController, SessionNotebookProvider) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let gist = try decoder.decode(
      Gist.self,
      from: Data(
        """
        {"id":"synthetic","description":"Session fixture","public":false,
        "created_at":"2026-10-23T00:00:00Z","updated_at":"2026-10-23T00:00:00Z",
        "owner":{"id":1,"login":"fixture"},
        "files":{"README.md":{"filename":"README.md","content":"Base"}}}
        """.utf8))
    let accountID = UUID()
    let store = try DraftStore.open(inMemory: true)
    var draft = try await store.openDraft(
      accountID: accountID, githubUserID: 1, gistID: gist.id, filename: "README.md",
      description: "Session fixture", content: "Base", revision: "1")
    if generation > 0 {
      draft = try await store.persist(
        id: draft.id, accountID: accountID, text: "Restored local draft", generation: generation)
    }
    let provider = SessionNotebookProvider(
      store: store, id: draft.id, accountID: accountID, autosave: autosave)
    let model = NotebookModel(provider: provider)
    if autosave != nil { await model.start() }
    let document = NotebookDocument(
      accountID: accountID, gist: gist, filename: "README.md", text: "Base",
      chrome: NoteChrome(
        title: "Session fixture", files: [.init(id: "README.md", filename: "README.md")],
        selectedFileID: "README.md"))
    return (
      NotebookSessionController(
        document: document, draft: draft, notebook: model, autosaveDelay: .milliseconds(30)),
      provider
    )
  }
}

private struct FocusNoteFixture: View {
  let controller: NotebookSessionController
  let focused: Bool

  var body: some View {
    NavigationStack {
      NoteScreen(
        document: controller.document.chrome, mode: .constant(.source),
        saveState: controller.saveState, isFocused: focused
      ) {
        MarkdownEditorView(session: controller.session)
      } preview: {
        Text("Preview companion")
      }
    }
  }
}

private actor SessionNotebookProvider: NotebookProviding {
  let store: DraftStore
  let id: UUID
  let accountID: UUID
  let autosave: Bool?
  private(set) var persistedGenerations: [UInt64] = []
  private(set) var publishCount = 0
  private(set) var publicationReasons: [PublishReason] = []
  private var persistenceFails = false
  private var publicationRejected = false
  private var publicationFailure: SaveState?
  private var remoteContent: String? = "Base"
  private var publishing: CheckedContinuation<Void, Never>?
  private var publishObserver: CheckedContinuation<Void, Never>?

  init(store: DraftStore, id: UUID, accountID: UUID, autosave: Bool? = nil) {
    self.store = store
    self.id = id
    self.accountID = accountID
    self.autosave = autosave
  }

  func cachedAccount() -> NotebookAccount? {
    guard let autosave else { return nil }
    return NotebookAccount(
      id: accountID, login: "fixture", githubUserID: 1,
      preferences: .init(metadata: ["isAutoSaveEnabled": .bool(autosave)]))
  }
  func signIn() throws -> NotebookAccount { throw AccountError.signedOut }
  func refreshAccount() throws -> NotebookAccount {
    guard let account = cachedAccount() else { throw AccountError.signedOut }
    return account
  }
  func gists(accountID: UUID) -> [Gist] { [] }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) throws -> Gist { throw GitHubClientError.missingFile }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    throw GitHubClientError.missingFile
  }
  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    try await snapshot()
  }

  func localState(accountID: UUID) async throws -> NotebookLocalState {
    NotebookLocalState(library: nil, drafts: try await store.drafts(accountID: accountID))
  }
  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {}
  func createDraft(accountID: UUID) throws -> DraftSnapshot { throw DraftError.notFound }
  func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote {
    throw DraftError.notFound
  }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    if case .inspectRemote(let id, let generation) = action {
      return .review(
        try await store.inspectRemoteChange(
          id: id, accountID: accountID, expectedGeneration: generation,
          remote: remoteContent, revision: "remote"))
    }
    throw DraftError.notFound
  }
  func setRemoteContent(_ content: String?) { remoteContent = content }

  func persist(
    draftID: UUID, accountID: UUID, text: String, generation: UInt64
  ) async throws -> DraftSnapshot {
    if persistenceFails { throw URLError(.cannotWriteToFile) }
    persistedGenerations.append(generation)
    return try await store.persist(
      id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> DraftSnapshot {
    if reason != .manual, !(await shouldPublish()) { throw CancellationError() }
    publishCount += 1
    publicationReasons.append(reason)
    if publicationRejected { throw DraftError.readOnly }
    if let publicationFailure {
      try await store.setState(publicationFailure, id: draftID, accountID: accountID)
      throw URLError(.timedOut)
    }
    let sent = try await snapshot()
    try await store.beginAttempt(
      id: draftID, accountID: accountID, content: sent.text,
      generation: sent.generation, remote: sent.baseContent)
    if reason == .manual {
      await withCheckedContinuation {
        publishing = $0
        publishObserver?.resume()
        publishObserver = nil
      }
    }
    return try await store.acknowledge(
      id: draftID, accountID: accountID, gistID: "synthetic",
      content: sent.text, revision: "2", generation: sent.generation)
  }

  func snapshot() async throws -> DraftSnapshot {
    try await store.draft(id: id, accountID: accountID)
  }

  func waitForPublish() async {
    if publishing != nil { return }
    await withCheckedContinuation { publishObserver = $0 }
  }

  func releasePublish() {
    publishing?.resume()
    publishing = nil
  }

  func failPersistence() { persistenceFails = true }
  func rejectPublication() { publicationRejected = true }
  func failPublication(with state: SaveState) { publicationFailure = state }
  func introduceConflict(remote: String?) async throws -> DraftSnapshot {
    let current = try await snapshot()
    try await store.setState(
      .conflict(
        .init(
          generation: current.generation, base: current.baseContent, local: current.text,
          remote: remote, remoteRevision: "2", suggestedMerge: nil)), id: id, accountID: accountID)
    return try await snapshot()
  }
}
