import Foundation
import GistPadEditor
import GistPadInterface
import GistPadPlatform
import SwiftUI
import Testing
import UIKit

@testable import GistPad
@testable import GistPadSync

@MainActor
struct NotebookModelTests {
  @Test func signOutDefersForegroundAndRouteRestorationUntilLocalCleanupFinishes() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Signing out")])
    let model = NotebookModel(provider: provider)
    await model.start()
    let cachedReads = await provider.cachedAccountReads
    let refreshReads = await provider.refreshAccountReads
    await provider.holdSignOut()
    let signOut = Task { try await model.perform(.signOut) }
    await provider.waitForSignOut()
    #expect(model.isSigningOut)
    await model.start()
    await model.refresh()
    await model.signIn()
    #expect(await provider.cachedAccountReads == cachedReads)
    #expect(await provider.refreshAccountReads == refreshReads)
    #expect(model.library.loadState == .ready)
    #expect(model.account?.id == fixtureAccount.id)
    await provider.releaseSignOut()
    _ = try await signOut.value
    #expect(!model.isSigningOut)
    #expect(model.account == nil)
    #expect(model.library.loadState == .signedOut)
  }

  @Test(arguments: [false, true])
  func signOutRetainsExactDraftsAndRestoresTheSameAccount(afterLocalCleanupFailure: Bool) async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Kept on this iPhone")])
    let selectionStore = NotebookSelectionStore()
    let model = NotebookModel(provider: provider, selections: selectionStore)
    await model.start()
    let text = "Private e\u{301}\r\n日本語 👩🏽‍💻"
    let draft = try await provider.stageExistingDraft(gistID: "a", text: text)
    await model.open(gistID: "a")
    try model.remember(.init(gistID: "a", filename: draft.filename, draftID: draft.id))
    await provider.failSignOut(afterLocalCleanup: afterLocalCleanupFailure)
    if afterLocalCleanupFailure {
      await #expect(throws: URLError.self) { _ = try await model.perform(.signOut) }
    } else {
      _ = try await model.perform(.signOut)
    }
    #expect(model.account == nil)
    #expect(model.loadedDocument == nil)
    #expect(model.cachedLibrary == nil)
    #expect(model.library.snapshot.notes.isEmpty)
    #expect(model.library.loadState == .signedOut)
    #expect(try selectionStore.selection(accountID: fixtureAccount.id)?.draftID == draft.id)
    let kept = try await provider.localState(accountID: fixtureAccount.id).drafts
    #expect(kept.count == 1)
    #expect(kept.first?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(await provider.publicationReasons.isEmpty)
    await model.signIn()
    #expect(model.account?.id == fixtureAccount.id)
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(model.loadedDocument?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func rejectedSignOutLeavesTheOpenAccountAndDraftIntact() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Still open")])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    let document = try #require(model.loadedDocument)
    await provider.rejectSignOut()
    await #expect(throws: URLError.self) { _ = try await model.perform(.signOut) }
    #expect(model.account?.id == fixtureAccount.id)
    #expect(model.loadedDocument?.id == document.id)
    #expect(model.loadedDocument?.text.utf8.elementsEqual(document.text.utf8) == true)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func accountIdentityOmitsMissingNamesAndUsesTheNativeAvatarURL() throws {
    let account = NotebookAccount(
      id: UUID(), login: "octavia", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"),
      preferences: .init(metadata: ["full_name": .string("  "), "name": .string("Octavia")]))
    #expect(account.displayName == "Octavia")
    #expect(account.avatarURL?.host == "avatars.githubusercontent.com")
    #expect(fixtureAccount.displayName == nil)
    #expect(NotebookModel.message(for: URLError(.notConnectedToInternet))
      == "You're offline. Connect to the internet, then try again.")
  }

  @Test func spellingPreferencesUpdateTheRetainedEditorWithoutChangingItsSourceOrSelection() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Spelling")])
    await provider.setSpellingEnabled(false)
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    let document = try #require(model.loadedDocument)
    let draft = try await model.openDraft(for: document)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    let editor = controller.session.textView
    #expect(editor.spellCheckingType == .no)
    editor.selectedRange = .init(location: 2, length: 3)
    let generation = controller.session.generation
    await provider.setSpellingEnabled(true)
    await model.refresh()
    try await controller.refreshMetadata()
    #expect(controller.session.textView === editor)
    #expect(editor.spellCheckingType == .yes)
    #expect(editor.selectedRange == .init(location: 2, length: 3))
    #expect(controller.session.text.utf8.elementsEqual(draft.text.utf8))
    #expect(controller.session.generation == generation)
  }

  @Test func platformRefreshRejectsAnotherAccountBeforeReadingAnyLocalState() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    let reads = await provider.localStateReads
    await #expect(throws: AccountError.accountChanged) {
      try await model.reloadPlatformState(accountID: UUID())
    }
    #expect(await provider.localStateReads == reads)
    try await model.reloadPlatformState(accountID: fixtureAccount.id)
    #expect(await provider.localStateReads == reads + 1)
  }

  @Test func offlinePresentationStaysTypedAndRetryable() {
    let state = NotebookModel.interfaceSaveState(.offline)
    #expect(state == .offline)
    #expect(state.canPublish)
  }

  @Test func todaySummaryDistinguishesEmptyExistingMissingAndUnknownWithoutExtraRequests() async throws {
    let filename = GistConventions.todayFilename()
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "daily", title: GistConventions.dailyNotesDescription,
          content: "", filename: filename)
      ])
    let model = NotebookModel(provider: provider)
    #expect(model.library.today.availability == .unknown)
    await model.start()
    #expect(model.library.today.availability == .existing)
    #expect(model.library.today.excerpt == nil)
    #expect(model.library.today.progress == .init(completed: 0, total: 0))
    let reads = await provider.readIDs
    await model.updateCalendar()
    #expect(await provider.readIDs == reads)
    #expect(await provider.todayTargets.isEmpty)
    #expect(await provider.creationCount == 0)

    let missingProvider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let missing = NotebookModel(provider: missingProvider)
    await missing.start()
    #expect(missing.library.today.availability == .missing)
    #expect(missing.library.today.excerpt == nil)
    #expect(await missingProvider.readIDs.isEmpty)
    #expect(await missingProvider.creationCount == 0)
  }

  @Test func anUnpublishedTodayReopensItsLocalDraftWithoutCreatingOrFetching() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.startToday()
    let daily = try #require(model.loadedDocument?.draft)
    #expect(daily.gistID == nil)
    #expect(model.library.today.availability == .existing)
    #expect(model.library.today.excerpt?.isEmpty == false)
    await model.createNote()
    #expect(model.loadedDocument?.draft?.id != daily.id)
    await model.showToday()
    #expect(model.loadedDocument?.draft?.id == daily.id)
    #expect(model.loadedDocument?.text == daily.text)
    #expect(await provider.todayTargets.count == 1)
    #expect(await provider.creationCount == 1)
    #expect(await provider.readIDs.isEmpty)
  }

  @Test func ordinaryGistOpensReadmeBeforeAnEarlierAlphabeticFileAndHonorsExplicitSelection() async throws {
    let gist = try makeGist(
      id: "multiple", title: "Multiple files", content: "Apple source", filename: "Apple.md",
      additionalFiles: ["README.md": "The actual README", "Zebra.md": "Zebra source"])
    let model = NotebookModel(provider: StubNotebookProvider(account: fixtureAccount, gists: [gist]))
    await model.start()
    await model.open(gistID: gist.id)
    #expect(model.loadedDocument?.filename == "README.md")
    #expect(model.loadedDocument?.text == "The actual README")
    await model.open(gistID: gist.id, filename: "Zebra.md")
    #expect(model.loadedDocument?.filename == "Zebra.md")
    #expect(model.loadedDocument?.text == "Zebra source")
  }

  @Test func accountSwitchKeepsAndExportsExactOriginalAccountDrafts() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Original account")])
    let model = NotebookModel(provider: provider)
    await model.start()
    let text = "日本語 e\u{301}\r\n**Private draft**"
    let local = try await provider.stageExistingDraft(gistID: "a", text: text)
    let replacement = NotebookAccount(
      id: UUID(), login: "other-account", preferences: .init(metadata: [:]))
    await provider.setSignInAccount(replacement)
    await model.signIn()
    let export = try await model.exportCurrentDrafts()
    let json = try #require(
      try JSONSerialization.jsonObject(with: export) as? [String: Any])
    let rows = try #require(json["drafts"] as? [[String: Any]])
    #expect(json["accountID"] as? String == fixtureAccount.id.uuidString)
    #expect(rows.count == 1)
    #expect((rows.first?["text"] as? String)?.utf8.elementsEqual(text.utf8) == true)
    model.keepCurrentNotebook()
    #expect(model.account?.id == fixtureAccount.id)
    #expect(model.pendingAccount == nil)
    let state = try await provider.localState(accountID: fixtureAccount.id)
    #expect(state.drafts.first?.id == local.id)
    #expect(state.drafts.first?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(try await provider.localState(accountID: replacement.id).drafts.isEmpty)
  }

  @Test func archiveUndoRequiresTheExactAccountAndUnchangedRemoteMetadata() throws {
    let original = try makeGist(id: "a", title: "Caf\u{E9} [Archived]")
    let undo = NotebookArchiveUndo(
      accountID: fixtureAccount.id, gistID: "a", originalDescription: "Caf\u{E9}",
      archivedDescription: original.description ?? "", wasArchived: false)
    try undo.validate(gist: original, accountID: fixtureAccount.id)
    #expect(throws: AccountError.accountChanged) {
      try undo.validate(gist: original, accountID: UUID())
    }
    let renamed = try makeGist(id: "a", title: "Cafe\u{301} [Archived]")
    #expect(throws: NotebookActionError.archiveChangedElsewhere) {
      try undo.validate(gist: renamed, accountID: fixtureAccount.id)
    }
  }

  @Test func mapsOwnedStarredAndWebMetadataWithoutDuplicates() throws {
    let owned = try makeGist(id: "a", title: "A note")
    let starred = try makeGist(id: "b", title: "A shared note", owner: "someone")
    let snapshot = NotebookModel.librarySnapshot(
      owned: [owned], starred: [owned, starred], account: fixtureAccount
    )
    #expect(snapshot.notes.count == 2)
    let note = try #require(snapshot.notes.first { $0.id == "a" })
    #expect(note.isOwned)
    #expect(note.isStarred)
    #expect(note.isPinned)
    #expect(note.isSecret)
    #expect(note.tagIDs == ["ideas"])
    #expect(note.fileCount == 1)
    #expect(snapshot.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
    #expect(snapshot.notes.first { $0.id == "b" }?.isOwned == false)
  }

  @Test func fileCountsUseKnownMetadataAndDoNotInventCompleteness() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "complete", title: "Complete", additionalFiles: ["Second.md": "Other source"]),
        try makeGist(id: "incomplete", title: "Incomplete", truncated: true),
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    #expect(model.library.snapshot.notes.first(where: { $0.id == "complete" })?.fileCount == 2)
    #expect(model.library.snapshot.notes.first(where: { $0.id == "incomplete" })?.fileCount == nil)
    model.library.query = "Synthetic"
    await model.search()
    #expect(model.library.matchingNotes.first(where: { $0.id == "complete/README.md" })?.fileCount == 2)
    #expect(model.library.matchingNotes.first(where: { $0.id == "incomplete" })?.fileCount == nil)
    #expect(await provider.readIDs.isEmpty)
  }

  @Test func ordinaryLibraryExcerptsUseTheDefaultFileAndPreferDirtyLocalSourceWithoutFetching() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Dirty local note", content: "Cached base"),
        try makeGist(
          id: "b", title: "Multiple", content: "Wrong alphabetical file", filename: "Apple.md",
          additionalFiles: ["README.md": "A real cached excerpt\nwith another line"]),
      ])
    _ = try await provider.stageExistingDraft(gistID: "a", text: "  The local thought\nwins  ")
    let model = NotebookModel(provider: provider)
    await model.start()
    #expect(model.library.snapshot.notes.first(where: { $0.id == "a" })?.excerpt == "The local thought wins")
    #expect(model.library.snapshot.notes.first(where: { $0.id == "b" })?.excerpt == "A real cached excerpt with another line")
    #expect(await provider.readIDs.isEmpty)
  }

  @Test func refreshDoesNotReplaceAnOpenedDocumentOrFilters() async throws {
    let original = try makeGist(id: "a", title: "Original", content: "Original text")
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [original])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    model.library.query = "Original"
    model.library.selectedTagIDs = ["ideas"]
    await provider.setGists([
      try makeGist(id: "a", title: "Changed remotely", content: "Remote text")
    ])
    await model.refresh()
    #expect(model.library.snapshot.notes.first?.title == "Changed remotely")
    #expect(model.loadedDocument?.text == "Original text")
    #expect(model.library.query == "Original")
    #expect(model.library.selectedTagIDs == ["ideas"])
    #expect(model.library.openDocumentOutsideFilter?.id == "a")
  }

  @Test func anOlderOpenCannotReplaceTheNewerSelection() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "First"), try makeGist(id: "b", title: "Second")],
      cachesContent: false
    )
    let model = NotebookModel(provider: provider)
    await model.start()
    await provider.holdRead(id: "a")
    let firstOpen = Task { await model.open(gistID: "a") }
    await provider.waitForHeldRead()
    await model.open(gistID: "b")
    await provider.releaseRead()
    await firstOpen.value
    #expect(model.loadedDocument?.gist?.id == "b")
    #expect(model.library.selectedNoteID == "b")
    #expect(!model.isOpeningDocument)
  }

  @Test func cachedSelectionPresentsTheTargetSynchronouslyWithoutRemoteReads() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "First", content: "First source"),
        try makeGist(id: "b", title: "Second", content: "Second source"),
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    let first = try #require(model.loadedDocument)
    let reads = await provider.readIDs
    #expect(model.beginOpeningRow(id: "b"))
    #expect(model.presentedDocument?.chrome.title == "Second")
    #expect(model.presentedDocument?.text == "Second source")
    #expect(model.presentedDocument?.refersToSameFile(as: first) == false)
    #expect(model.openingDocument == nil)
    #expect(!model.isOpeningDocument)
    #expect(await provider.readIDs == reads)
  }

  @Test func selectionBeforeTheAsyncObserverCannotPresentThePreviousDocument() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "First", content: "First source"),
        try makeGist(id: "b", title: "Second", content: "Second source"),
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    model.library.selectedNoteID = "b"
    #expect(model.loadedDocument?.gist?.id == "a")
    #expect(model.presentedDocument?.gist?.id == "b")
    #expect(model.presentedDocument?.text == "Second source")
  }

  @Test func uncachedSelectionHasTheNewTitleAndCannotResurrectAnOlderRequest() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "First"),
        try makeGist(id: "b", title: "Second"),
      ], cachesContent: false)
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "b")
    await provider.holdRead(id: "a")
    #expect(!model.beginOpeningRow(id: "a"))
    #expect(model.presentedDocument == nil)
    #expect(model.openingTitle == "First")
    let first = Task { await model.openRow(id: "a") }
    await provider.waitForHeldRead()
    #expect(!model.beginOpeningRow(id: "b"))
    #expect(model.openingTitle == "Second")
    #expect(model.presentedDocument == nil)
    await model.openRow(id: "b")
    await provider.releaseRead()
    await first.value
    #expect(model.presentedDocument?.gist?.id == "b")
    #expect(model.openingDocument == nil)
  }

  @Test func failedOpenKeepsTheRequestedTitleAndRetriesTheExactFileWithoutShowingThePreviousNote() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Previous", content: "Previous source"),
        try makeGist(
          id: "b", title: "Requested", additionalFiles: ["Other.md": "Exact selected file"]),
      ], cachesContent: false)
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    model.library.query = "Requested"
    await model.search()
    await provider.setReadFailure(id: "b", fails: true)
    await model.open(gistID: "b", filename: "Other.md", rowID: "search-result")
    #expect(model.loadedDocument?.gist?.id == "a")
    #expect(model.presentedDocument == nil)
    #expect(model.failedOpen?.gistID == "b")
    #expect(model.failedOpen?.filename == "Other.md")
    #expect(model.failedOpen?.title == "Requested")
    #expect(model.library.selectedNoteID == "search-result")
    #expect(model.documentError == nil)
    #expect(!model.isOpeningDocument)
    await provider.setReadFailure(id: "b", fails: false)
    await model.retryFailedOpen()
    #expect(model.failedOpen == nil)
    #expect(model.presentedDocument?.text == "Exact selected file")
    #expect(model.presentedDocument?.rowID == "search-result")
  }

  @Test func creationPresentsDurableContentBeforeAnyLocalReloadOrSearch() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    let reloads = await provider.localStateReads
    await provider.failRequests()
    await model.createNote()
    let document = try #require(model.presentedDocument)
    let draft = try #require(document.draft)
    #expect(document.opensForEditing)
    #expect(model.localDrafts.first?.id == draft.id)
    #expect(model.library.snapshot.notes.contains { $0.id == draft.id.uuidString })
    #expect(await provider.localStateReads == reloads)
    #expect(await provider.readIDs.isEmpty)
    #expect(model.documentError == nil)
  }

  @Test func networkFailureKeepsExistingLibraryAndDocument() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "A note")]
    )
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    await provider.failRequests()
    await model.refresh()
    #expect(model.library.snapshot.notes.count == 1)
    #expect(model.loadedDocument?.gist?.id == "a")
    guard case .failed(let message) = model.library.loadState else {
      Issue.record("A failed refresh must remain visible.")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test func accountSwitchWaitsForLocalWorkDisposition() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "A note")]
    )
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    let replacement = NotebookAccount(
      id: UUID(), login: "another-person", preferences: .init(metadata: [:]))
    await provider.setSignInAccount(replacement)
    await model.signIn()
    #expect(model.account?.id == fixtureAccount.id)
    #expect(model.pendingAccount?.id == replacement.id)
    #expect(model.loadedDocument?.accountID == fixtureAccount.id)
    guard case .reconnectRequired = model.library.loadState else {
      Issue.record("An account switch must not silently adopt another account.")
      return
    }
  }

  @Test func uncertainCreatesAndReconnectsCannotPublish() {
    #expect(NotebookModel.interfaceSaveState(.savedLocally) == .savedLocally)
    #expect(NotebookModel.interfaceSaveState(.savedToGitHub) == .savedToGitHub)
    #expect(NotebookModel.interfaceSaveState(.reconnect) == .reconnectRequired)
    let uncertain = NotebookModel.interfaceSaveState(.failed(.creationUncertain))
    #expect(uncertain == .creationUncertain)
    #expect(!uncertain.canPublish)
    #expect(!NotebookModel.interfaceSaveState(.failed(.incompleteRemote)).canPublish)
    #expect(!NotebookModel.interfaceSaveState(.failed(.readOnly)).canPublish)
  }

  @Test func launchRestoresTheAccountScopedFileWithoutCreatingAnything() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Last chosen")])
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
    try selections.save(
      .init(gistID: "someone-elses-note", filename: "private.md", draftID: nil),
      accountID: UUID())
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "a")
    #expect(model.loadedDocument?.filename == "README.md")
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
    await model.refresh()
    #expect(model.loadedDocument?.gist?.id == "a")
  }

  @Test func missingTodayShowsALandingUntilTheExplicitStartAction() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    #expect(model.loadedDocument == nil)
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
    let target = DailyNoteTarget(
      date: Date(timeIntervalSince1970: 1_790_208_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    await model.startToday(target: target)
    #expect(await provider.todayTargets == [target])
    #expect(model.loadedDocument?.draft?.filename == target.filename)
  }

  @Test func launchOpensExistingTodayWithoutCallingTheCreatingService() async throws {
    let filename = GistConventions.todayFilename()
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "daily", title: GistConventions.dailyNotesDescription, filename: filename)
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "daily")
    #expect(model.loadedDocument?.filename == filename)
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
  }

  @Test func aMissingRemotePreservesTheLocalDraftAndItsGeneration() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let draft = try await provider.stageExistingDraft(
      gistID: "deleted", text: "Keep my exact draft")
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "deleted", filename: draft.filename, draftID: nil),
      accountID: fixtureAccount.id)
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(model.loadedDocument?.draft?.generation == 8)
    #expect(model.loadedDocument?.text == "Keep my exact draft")
    #expect(model.loadedDocument?.isRecovery == true)
    #expect(model.documentError != nil)
    #expect(await provider.creationCount == 0)
  }

  @Test func newNotesAreRealDurableLocalDraftsWithoutASyntheticGist() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.createNote()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    #expect(document.gist == nil)
    #expect(document.opensForEditing)
    #expect(draft.gistID == nil)
    #expect(draft.state == .savedLocally)
    #expect(await provider.creationCount == 1)
    #expect(await provider.todayTargets.isEmpty)
    await model.refresh()
    await model.refresh()
    #expect(model.library.snapshot.notes.filter { $0.id == draft.id.uuidString }.count == 1)
  }

  @Test func anUnrelatedAccountCannotRestoreThePreviousAccountsSelection() async throws {
    let other = NotebookAccount(id: UUID(), login: "other", preferences: .init(metadata: [:]))
    let provider = StubNotebookProvider(account: other, gists: [])
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument == nil)
    #expect(await provider.readIDs.isEmpty)
  }

  @Test func searchFindsCachedBodyTextAndNamedTagsWithoutTitleRefiltering() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Ordinary title", content: "A needle phrase in the body."),
        try makeGist(id: "b", title: "Needle phrase", content: "An untagged note."),
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    model.library.query = "\"needle phrase\" tag:Ideas"
    await model.search()
    #expect(model.library.matchingNotes.map(\.id) == ["a"])
    guard case .results(_, let coverage) = model.library.searchState else {
      Issue.record("Full-text results must carry honest cache coverage.")
      return
    }
    #expect(coverage.totalDocuments == 2)
    #expect(coverage.documentsWithCachedContent == 2)
    model.library.query = "tag:Missing"
    await model.search()
    guard case .failed(let message) = model.library.searchState else {
      Issue.record("An unknown tag must be an explicit search error.")
      return
    }
    #expect(message.contains("Missing"))
    #expect(model.library.matchingNotes.isEmpty)
  }

  @Test func dailySearchRowsOpenTheirExactFile() async throws {
    let filename = GistConventions.todayFilename()
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "daily", title: GistConventions.dailyNotesDescription,
          content: "- [x] One\n- [ ] Two\nA third line stays out of the excerpt.", filename: filename)
      ])
    let model = NotebookModel(provider: provider)
    await model.start()
    model.library.collection = .dailyNotes
    await model.search()
    let row = try #require(model.library.matchingNotes.first)
    #expect(row.id == "daily/\(filename)")
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(model.library.today.excerpt == "- [x] One\n- [ ] Two")
    await model.openRow(id: row.id)
    #expect(model.loadedDocument?.filename == filename)
    #expect(model.library.selectedNoteID == row.id)
  }
}

@Suite(.serialized)
@MainActor
struct NotebookNavigationHostTests {
  @Test func sourceIntelligenceOpensTheLiveSheetForTheRetainedEditor() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "A retained thought", content: "A little room to think.")])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "A little room to think.") != nil }
    let editor = try #require(host.editor(text: "A little room to think."))
    editor.becomeFirstResponder()
    try await host.waitUntil { editor.isFirstResponder }
    let selection = NSRange(location: 2, length: 6)
    editor.selectedRange = selection
    let accessory = try #require(editor.inputAccessoryView)
    let entry = try #require(
      host.descendants(of: accessory).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == "editor-intelligence"
      })
    #expect(entry.isEnabled)
    entry.performPrimaryAction()
    try await host.waitUntil {
      notebookAccessibilityElement(
        "capture-frame-note-intelligence-sheet", in: host.window) != nil
    }
    #expect(!editor.isFirstResponder)
    #expect(editor.selectedRange == selection)
    #expect(host.editor(text: "A little room to think.") === editor)
    let image = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
      host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "live-source-intelligence-entry-no-generation.png", as: .png)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func aFailedOpenShowsItsOwnTitleAndRetryInsteadOfThePreviousEditor() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Previous", content: "Previous source"),
        try makeGist(id: "b", title: "Requested", additionalFiles: ["Other.md": "Retried source"]),
      ], cachesContent: false)
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Previous source") != nil }
    await provider.setReadFailure(id: "b", fails: true)
    await host.model.open(gistID: "b", filename: "Other.md", rowID: "result-b")
    try await host.waitUntil {
      host.descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }.contains("Requested")
    }
    #expect(host.editor(text: "Previous source") == nil)
    host.window.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
      host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "failed-open-complete-workspace.png", as: .png)
    await provider.setReadFailure(id: "b", fails: false)
    await host.model.retryFailedOpen()
    try await host.waitUntil { host.editor(text: "Retried source") != nil }
    #expect(notebookAccessibilityElement("note-open-retry", in: host.window) == nil)
    #expect(host.model.loadedDocument?.gist?.id == "b")
    #expect(host.model.library.selectedNoteID == "b")
    #expect(host.model.loadedDocument?.filename == "Other.md")
  }

  @Test func returningToLibrarySavesTheOutgoingNoteWithoutWaitingForTheQuietTimer() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Current", content: "Current source")])
    let host = try await NavigationHost(provider: provider, autosave: true, sizeClass: .compact)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 0, length: 0)
    editor.insertText("Local ")
    try await host.waitUntil { host.model.localDrafts.first?.generation == 1 }
    host.routes.submit(.library)
    try await host.waitUntil(timeout: .seconds(1)) {
      host.routes.pending == nil && host.model.localDrafts.first?.state == .savedToGitHub
    }
    try await host.waitUntil { host.isLibraryVisible }
    #expect(await provider.publicationReasons == [.autosave])
    #expect(host.model.loadedDocument?.gist?.id == "a")
    #expect(host.model.library.selectedNoteID == nil)
    #expect(!editor.isFirstResponder)
    let image = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
      host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "library-visible-after-compact-route.png", as: .png)
    let selection = editor.selectedRange
    host.routes.submit(.note(gistID: "a", filename: nil, shared: false))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "Local Current source") === editor
        && !host.isLibraryVisible
    }
    #expect(editor.selectedRange == selection)
  }

  @Test func returningToLibraryWithAutosaveOffKeepsLocalChangesAndTheRetainedEditor() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Current", content: "Current source")])
    let host = try await NavigationHost(provider: provider, sizeClass: .compact)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 0, length: 0)
    editor.insertText("Local ")
    try await host.waitUntil { host.model.localDrafts.first?.generation == 1 }
    host.routes.submit(.library)
    try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    #expect(host.model.library.selectedNoteID == nil)
    #expect(host.model.localDrafts.first?.text == "Local Current source")
    #expect(host.model.localDrafts.first?.state == .savedLocally)
    #expect(await provider.publicationReasons.isEmpty)
    #expect(!editor.isFirstResponder)
    let selection = editor.selectedRange
    host.routes.submit(.note(gistID: "a", filename: nil, shared: false))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "Local Current source") === editor
        && !host.isLibraryVisible
    }
    #expect(editor.selectedRange == selection)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test(arguments: [false, true])
  func compactLibraryRoundTripBringsTheRealKeyboardBackOnScreen(
    settledKeyboard: Bool
  ) async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Current", content: "Current source")])
    let host = try await NavigationHost(provider: provider, sizeClass: .compact)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.selectedRange = .init(location: 2, length: 6)
    try #require(editor.becomeFirstResponder())
    if settledKeyboard { try await host.waitForKeyboard(visible: true) }
    host.recordKeyboard(named: "library-round-trip-before-pop")
    host.routes.submit(try NotebookRoute(url: #require(URL(string: "gistpad://library"))))
    try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    try await host.waitForKeyboard(visible: false)
    host.recordKeyboard(named: "library-round-trip-after-pop")
    #expect(!editor.isFirstResponder)
    host.routes.submit(.note(gistID: "a", filename: nil, shared: false))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "Current source") === editor
        && !host.isLibraryVisible
    }
    try #require(editor.becomeFirstResponder())
    try await host.waitForKeyboard(visible: true)
    host.recordKeyboard(named: "library-round-trip-refocused")
    #expect(editor.selectedRange == NSRange(location: 2, length: 6))
    #expect(await provider.publicationReasons.isEmpty)
    editor.resignFirstResponder()
    try await host.waitForKeyboard(visible: false)
  }

  @Test(arguments: ["gistpad://library", "https://gistpad.dev/"])
  func libraryLinksDoNotSelectTheTodayPlaceholderWhenNoNoteIsOpen(address: String) async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let routes = NotebookRouteInbox()
    routes.submit(try NotebookRoute(url: #require(URL(string: address))))
    let host = try await NavigationHost(provider: provider, routes: routes, sizeClass: .compact)
    defer { await host.close() }
    try await host.waitUntil { routes.pending == nil && host.isLibraryVisible }
    try await Task.sleep(for: .milliseconds(300))
    #expect(host.isLibraryVisible)
    #expect(host.model.loadedDocument == nil)
    #expect(host.model.library.selectedNoteID == nil)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test(arguments: ["gistpad://library", "https://gistpad.dev/"], [false, true])
  func libraryLinksShowTheActualLibraryInsteadOfLeavingTheRestoredNotePushed(
    address: String, cold: Bool
  ) async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Current", content: "Current source")])
    let route = try NotebookRoute(url: #require(URL(string: address)))
    let routes = NotebookRouteInbox()
    if cold { routes.submit(route) }
    let host = try await NavigationHost(
      provider: provider, routes: routes, sizeClass: .compact,
      restoredSelection: cold ? .init(gistID: "a", filename: "README.md", draftID: nil) : nil)
    defer { await host.close() }
    if !cold {
      await host.model.open(gistID: "a")
      try await host.waitUntil { host.editor(text: "Current source") != nil }
      #expect(!host.isLibraryVisible)
      routes.submit(route)
    }
    try await host.waitUntil { routes.pending == nil && host.isLibraryVisible }
    try await Task.sleep(for: .milliseconds(300))
    #expect(host.isLibraryVisible)
    #expect(host.model.loadedDocument?.gist?.id == "a")
    #expect(host.model.library.selectedNoteID == nil)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func returningToLibraryCancelsAnUncachedListSelectionWithoutLosingThePreviousNote() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Current", content: "Current source"),
        try makeGist(id: "b", title: "Held", content: "Held source"),
      ], cachesContent: false)
    let host = try await NavigationHost(provider: provider, sizeClass: .compact)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    await provider.holdRead(id: "b")
    defer { Task { await provider.releaseRead() } }
    #expect(!host.model.beginOpeningRow(id: "b"))
    let opening = Task { await host.model.openRow(id: "b") }
    await provider.waitForHeldRead()
    host.routes.submit(.library)
    try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    await provider.releaseRead()
    await opening.value
    #expect(host.isLibraryVisible)
    #expect(host.model.library.selectedNoteID == nil)
    #expect(host.model.loadedDocument?.gist?.id == "a")
    #expect(host.model.openingDocument == nil)
    #expect(host.editor(text: "Held source") == nil)
  }

  @Test(arguments: ["gistpad://library", "https://gistpad.dev/"])
  func regularWidthLibraryLinksRevealTheSidebarWithoutClosingOrDefocusingTheNote(
    address: String
  ) async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Current", content: "Current source")])
    let host = try await NavigationHost(
      provider: provider, sizeClass: .regular, columnVisibility: .detailOnly)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 2, length: 6)
    try await host.waitUntil { editor.isFirstResponder && !host.isLibraryVisible }
    let selection = host.model.library.selectedNoteID
    let range = editor.selectedRange
    host.routes.submit(try NotebookRoute(url: #require(URL(string: address))))
    try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    #expect(host.model.library.selectedNoteID == selection)
    #expect(host.model.loadedDocument?.gist?.id == "a")
    #expect(host.editor(text: "Current source") === editor)
    #expect(host.isVisible(editor))
    #expect(editor.isFirstResponder)
    #expect(editor.selectedRange == range)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func aColdRouteWaitsForRestorationAndOpensTheExactFile() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(
        id: "b", title: "Routed note", additionalFiles: ["Ideas.md": "Routed file source"])])
    let routes = NotebookRouteInbox()
    routes.submit(.note(gistID: "b", filename: "Ideas.md", shared: false))
    let host = try await NavigationHost(provider: provider, routes: routes)
    defer { await host.close() }
    try await host.waitUntil {
      routes.pending == nil && host.editor(text: "Routed file source") != nil
    }
    #expect(host.model.loadedDocument?.filename == "Ideas.md")
    #expect(host.model.loadedDocument?.gist?.id == "b")
  }

  @Test func sharedRoutesStartInPreviewWithoutChangingTheSavedSourcePreference() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "b", title: "Shared note", content: "Shared source")])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    host.routes.submit(.note(gistID: "b", filename: nil, shared: true))
    try await host.waitUntil {
      host.routes.pending == nil
        && host.descendants.compactMap { $0 as? UISegmentedControl }
          .contains { $0.selectedSegmentIndex == 1 }
    }
    #expect(host.layout.preferredMode == .source)
    #expect(host.editor(text: "Shared source")?.isFirstResponder != true)
    #expect(host.model.loadedDocument?.gist?.id == "b")
  }

  @Test func aNewNoteRouteCreatesOneDurableEditingSessionAndAcknowledgesIt() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    host.routes.submit(.newNote)
    try await host.waitUntil {
      host.routes.pending == nil
        && host.model.loadedDocument?.draft.map { host.editor(text: $0.text)?.isFirstResponder == true }
          == true
    }
    #expect(await provider.creationCount == 1)
    #expect(host.model.loadedDocument?.draft?.baseContent == nil)
  }

  @Test func anotherAccountsDraftRouteNeverOpensOrChangesTheCurrentNote() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Current", content: "Current source")])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let previous = host.model.loadedDocument?.id
    host.routes.submit(.draft(accountID: UUID(), draftID: UUID()))
    try await host.waitUntil { host.routes.pending == nil }
    #expect(host.model.account?.id == fixtureAccount.id)
    #expect(host.model.loadedDocument?.id == previous)
  }

  @Test func aNewerRouteCannotBeAcknowledgedOrReplacedByAnOlderHeldRead() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "Held", content: "Held source"),
        try makeGist(id: "b", title: "Latest", content: "Latest source"),
      ], cachesContent: false)
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await provider.holdRead(id: "a")
    defer { Task { await provider.releaseRead() } }
    host.routes.submit(.note(gistID: "a", filename: nil, shared: false))
    await provider.waitForHeldRead()
    host.routes.submit(.note(gistID: "b", filename: nil, shared: false))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "Latest source") != nil
    }
    await provider.releaseRead()
    try await Task.sleep(for: .milliseconds(80))
    #expect(host.model.loadedDocument?.gist?.id == "b")
    #expect(host.model.library.selectedNoteID == "b")
    #expect(host.editor(text: "Held source") == nil)
  }

  @Test func returningToLibrarySupersedesAHeldRouteWithoutOpeningItLater() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Held", content: "Held source")],
      cachesContent: false)
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await provider.holdRead(id: "a")
    defer { Task { await provider.releaseRead() } }
    host.routes.submit(.note(gistID: "a", filename: nil, shared: false))
    await provider.waitForHeldRead()
    host.routes.submit(.library)
    try await host.waitUntil { host.routes.pending == nil }
    await provider.releaseRead()
    try await host.waitUntil { !host.model.isOpeningDocument }
    #expect(host.model.loadedDocument == nil)
    #expect(host.model.presentedDocument == nil)
    #expect(host.editor(text: "Held source") == nil)
  }

  @Test func leavingANoteSavesBeforeItsQuietTimerWithoutStealingThePendingSelection() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "First note", content: "First note source"),
        try makeGist(id: "b", title: "Second note", content: "Second note source"),
      ], cachesContent: false)
    let host = try await NavigationHost(provider: provider, autosave: true)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "First note source") != nil }
    let editor = try #require(host.editor(text: "First note source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 0, length: 0)
    editor.insertText("Local ")
    try await host.waitUntil { host.model.localDrafts.first?.generation == 1 }
    await provider.holdRead(id: "b")
    defer { Task { await provider.releaseRead() } }
    #expect(!host.model.beginOpeningRow(id: "b"))
    let opening = Task { await host.model.openRow(id: "b") }
    await provider.waitForHeldRead()
    try await host.waitUntil(timeout: .seconds(1)) {
      host.model.localDrafts.first?.state == .savedToGitHub
    }
    #expect(await provider.publicationReasons == [.autosave])
    #expect(host.model.library.selectedNoteID == "b")
    #expect(host.model.openingTitle == "Second note")
    #expect(host.model.presentedDocument == nil)
    await provider.releaseRead()
    await opening.value
    try await host.waitUntil { host.editor(text: "Second note source") != nil }
  }

  @Test func anUncachedSelectionUnmountsThePreviousEditorWhileTheRequestIsStillHeld() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "First note", content: "First note source"),
        try makeGist(id: "b", title: "Second note", content: "Second note source"),
      ], cachesContent: false)
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "First note source") != nil }
    let original = try #require(host.editor(text: "First note source"))
    await provider.holdRead(id: "b")
    defer { Task { await provider.releaseRead() } }
    #expect(!host.model.beginOpeningRow(id: "b"))
    let opening = Task { await host.model.openRow(id: "b") }
    await provider.waitForHeldRead()
    try await host.waitUntil {
      original.window == nil
        && host.descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }
          .contains("Second note")
    }
    #expect(host.model.presentedDocument == nil)
    #expect(host.model.openingTitle == "Second note")
    #expect(host.editor(text: "First note source") == nil)
    let navigationTitles = host.descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }
    #expect(navigationTitles.contains("Second note"))
    await provider.releaseRead()
    await opening.value
    try await host.waitUntil { host.editor(text: "Second note source") != nil }
    #expect(original.window == nil)
  }

  @Test func cachedSwitchingMountsTheRightSourceAndRetainsIndependentSelectionAndUndo() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(id: "a", title: "First note", content: "First note source"),
        try makeGist(id: "b", title: "Second note", content: "Second note source"),
      ])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    #expect(host.model.beginOpeningRow(id: "a"))
    try await host.waitUntil { host.editor(text: "First note source") != nil }
    let first = try #require(host.editor(text: "First note source"))
    first.becomeFirstResponder()
    first.selectedRange = NSRange(location: 0, length: 0)
    first.undoManager?.beginUndoGrouping()
    first.insertText("Local ")
    first.undoManager?.endUndoGrouping()
    let selection = first.selectedRange
    let reads = await provider.readIDs
    #expect(host.model.beginOpeningRow(id: "b"))
    #expect(host.model.presentedDocument?.text == "Second note source")
    #expect(host.model.openingDocument == nil)
    try await host.waitUntil { host.editor(text: "Second note source") != nil }
    #expect(first.window == nil)
    #expect(await provider.readIDs == reads)
    #expect(host.model.beginOpeningRow(id: "a"))
    try await host.waitUntil { first.window === host.window }
    #expect(first.selectedRange == selection)
    #expect(first.text == "Local First note source")
    first.undoManager?.undo()
    #expect(first.text == "First note source")
    #expect(await provider.readIDs == reads)
  }

  @Test func creatingOfflineReplacesTheOldNoteWithAnEditingFirstResponder() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "a", title: "Previous note", content: "Previous source")])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await host.model.open(gistID: "a")
    try await host.waitUntil { host.editor(text: "Previous source") != nil }
    let previous = try #require(host.editor(text: "Previous source"))
    await provider.failRequests()
    await host.model.createNote()
    let draft = try #require(host.model.presentedDocument?.draft)
    try await host.waitUntil { host.editor(text: draft.text)?.isFirstResponder == true }
    let editor = try #require(host.editor(text: draft.text))
    #expect(editor !== previous)
    #expect(previous.window == nil)
    #expect(editor.selectedRange == NSRange(location: draft.text.utf16.count, length: 0))
    #expect(await provider.creationCount == 1)
    #expect(await provider.readIDs.isEmpty)
    #expect(host.model.presentedDocument?.chrome.title == "Untitled")
    editor.insertText("A local thought 🙂")
    try await host.waitUntil { host.model.localDrafts.first(where: { $0.id == draft.id })?.generation == 1 }
    #expect(host.model.localDrafts.first(where: { $0.id == draft.id })?.text == "A local thought 🙂")
  }

  @Test func startingTodayFocusesTheCaretAfterItsDurableInitialContent() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let host = try await NavigationHost(provider: provider)
    defer { await host.close() }
    await host.model.startToday()
    let draft = try #require(host.model.presentedDocument?.draft)
    #expect(!draft.text.isEmpty)
    try await host.waitUntil { host.editor(text: draft.text)?.isFirstResponder == true }
    let editor = try #require(host.editor(text: draft.text))
    #expect(editor.selectedRange == NSRange(location: draft.text.utf16.count, length: 0))
    #expect(await provider.todayTargets.count == 1)
    #expect(await provider.readIDs.isEmpty)
    #expect(await provider.creationCount == 0)
  }
}

@MainActor
private struct NavigationHost {
  let model: NotebookModel
  let window: UIWindow
  let routes: NotebookRouteInbox
  let layout: NotebookLayoutPreferences
  private let suite: String
  private let previousWindow: UIWindow?

  init(
    provider: StubNotebookProvider, autosave: Bool = false,
    routes: NotebookRouteInbox = NotebookRouteInbox(),
    sizeClass: UIUserInterfaceSizeClass? = nil,
    columnVisibility: NavigationSplitViewVisibility = .all,
    restoredSelection: NotebookSelection? = nil
  ) async throws {
    self.routes = routes
    await provider.setAutosaveEnabled(autosave)
    suite = "NotebookNavigationHost-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    layout = NotebookLayoutPreferences(defaults: defaults)
    layout.select(.source)
    let selections = NotebookSelectionStore()
    if let restoredSelection {
      try selections.save(restoredSelection, accountID: fixtureAccount.id)
    }
    model = NotebookModel(provider: provider, selections: selections)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previousWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    let sceneBounds = scene.effectiveGeometry.coordinateSpace.bounds
    window.frame = CGRect(
      origin: sceneBounds.origin,
      size: CGSize(
        width: sizeClass == .regular ? 1180 : sceneBounds.width, height: sceneBounds.height))
    if let sizeClass { window.traitOverrides.horizontalSizeClass = sizeClass }
    window.rootViewController = UIHostingController(
      rootView: LiveNotebookWorkspace(notebook: model, layout: layout, routes: routes)
        .captureColumnVisibility(columnVisibility)
        .environment(\.scenePhase, .active))
    window.makeKeyAndVisible()
    try await waitUntil { model.library.loadState == .ready && model.cachedLibrary != nil }
  }

  var descendants: [UIView] {
    descendants(of: window)
  }

  func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  func editor(text: String) -> UITextView? {
    descendants.compactMap { $0 as? UITextView }.first { $0.text == text && $0.window === window }
  }

  var isLibraryVisible: Bool {
    let bars = descendants.compactMap { $0 as? UINavigationBar }.filter {
      $0.topItem?.title == "Library" && isVisible($0)
    }
    for bar in bars {
      let frame = bar.convert(bar.bounds, to: window)
      let viewport = window.bounds.inset(by: window.safeAreaInsets)
      let point = CGPoint(
        x: frame.intersection(viewport).midX, y: max(viewport.minY, frame.maxY) + 44)
      guard viewport.contains(point) else { continue }
      var hit = window.hitTest(point, with: nil)
      while let view = hit {
        if view is UICollectionView || view is UITableView { return true }
        hit = view.superview
      }
    }
    return false
  }

  func isVisible(_ view: UIView) -> Bool {
    guard view.window === window, !view.bounds.isEmpty else { return false }
    var ancestor: UIView? = view
    while let current = ancestor {
      if current.isHidden || current.alpha < 0.01 { return false }
      ancestor = current.superview
    }
    return window.bounds.insetBy(dx: -0.5, dy: -0.5)
      .contains(view.convert(view.bounds, to: window))
  }

  private var keyboardFrame: CGRect {
    guard let view = window.rootViewController?.view else { return .null }
    return view.convert(view.keyboardLayoutGuide.layoutFrame, to: window)
  }

  func waitForKeyboard(visible: Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var previous: CGRect?
    var stableSince = ContinuousClock.now
    while ContinuousClock.now < deadline {
      window.rootViewController?.view.layoutIfNeeded()
      let frame = keyboardFrame
      let matches = visible
        ? frame.height > 100
          && window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
        : !frame.isNull && frame.height <= window.safeAreaInsets.bottom + 1
      if matches {
        if previous == frame {
          if ContinuousClock.now - stableSince >= .milliseconds(350) { return }
        } else {
          stableSince = ContinuousClock.now
          previous = frame
        }
      } else {
        previous = nil
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    recordKeyboard(named: visible ? "keyboard-not-on-screen" : "keyboard-not-dismissed")
    Issue.record("The real keyboard did not settle \(visible ? "on screen" : "off screen").")
    throw HostError.presentationTimedOut
  }

  func recordKeyboard(named name: String) {
    Attachment.record(
      """
      window: \(window.bounds), safe area: \(window.safeAreaInsets)
      keyboard: \(keyboardFrame)
      editors: \(descendants.compactMap { ($0 as? UITextView).map { "\($0.isFirstResponder): \($0.frame)" } })
      """, named: "\(name).txt")
  }

  func waitUntil(
    timeout: Duration = .seconds(5), _ predicate: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        Attachment.record(
          """
          account: \(String(describing: model.account?.id))
          load: \(model.library.loadState)
          loaded: \(String(describing: model.loadedDocument?.id))
          presented: \(String(describing: model.presentedDocument?.id))
          opening: \(String(describing: model.openingTitle))
          failed: \(String(describing: model.failedOpen))
          error: \(String(describing: model.documentError))
          route: \(String(describing: routes.pending))
          library visible: \(isLibraryVisible)
          window: \(window.bounds), safe area: \(window.safeAreaInsets)
          editors: \(descendants.compactMap { ($0 as? UITextView)?.text })
          titles: \(descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title })
          """, named: "navigation-timeout.txt")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "navigation-timeout.png", as: .png)
        Issue.record("The mounted notebook did not reach its expected presentation.")
        throw HostError.presentationTimedOut
      }
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  func close() async {
    window.endEditing(true)
    window.rootViewController?.dismiss(animated: false)
    do {
      try await waitForKeyboard(visible: false)
    } catch {
      Issue.record(error, "Navigation host teardown did not finish dismissing its keyboard.")
    }
    if let root = window.rootViewController {
      func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
          + (controller.presentedViewController.map(controllers) ?? [])
      }
      do {
        try await waitUntil { controllers(root).allSatisfy { $0.transitionCoordinator == nil } }
      } catch {
        Issue.record(error, "Navigation host teardown interrupted a native transition.")
      }
    }
    window.isHidden = true
    window.rootViewController = nil
    previousWindow?.makeKeyAndVisible()
    UserDefaults.standard.removePersistentDomain(forName: suite)
  }

  private enum HostError: Error { case presentationTimedOut }
}

private let fixtureAccount = NotebookAccount(
  id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
  login: "notebook-owner",
  preferences: .init(metadata: [
    "pinnedGists": .array([.string("a")]),
    "tags": .object(["ideas": .object(["name": .string("Ideas"), "color": .string("#EBC85A")])]),
    "gistTags": .object(["a": .array([.string("ideas")])]),
  ])
)

private func makeGist(
  id: String, title: String, content: String = "Synthetic text", owner: String = "notebook-owner",
  filename: String = "README.md", additionalFiles: [String: String] = [:], truncated: Bool = false
) throws -> Gist {
  var files = additionalFiles
  files[filename] = content
  var filePayload: [String: [String: String]] = [:]
  for (name, source) in files {
    filePayload[name] = ["filename": name, "language": "Markdown", "content": source]
  }
  let json: [String: Any] = [
    "id": id, "description": title, "public": false, "truncated": truncated,
    "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
    "owner": ["id": 1, "login": owner],
    "files": filePayload,
    "history": [["version": "synthetic-revision"]],
  ]
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: json))
}

private actor StubNotebookProvider: NotebookProviding {
  private(set) var account: NotebookAccount
  var signInAccount: NotebookAccount
  var notes: [Gist]
  var shouldFail = false
  var heldID: String?
  var heldRead: CheckedContinuation<Void, Never>?
  var readObserver: CheckedContinuation<Void, Never>?
  var cached: CachedLibrarySnapshot?
  var store: DraftStore?
  let cachesContent: Bool
  private(set) var creationCount = 0
  private(set) var localStateReads = 0
  private(set) var todayTargets: [DailyNoteTarget] = []
  private(set) var readIDs: [String] = []
  private(set) var publicationReasons: [PublishReason] = []
  private var failingReadIDs: Set<String> = []
  private var isSignedOut = false
  private var failsSignOutAfterCleanup = false
  private var rejectsSignOut = false
  private var isSigningOut = false
  private var holdsSignOut = false
  private var heldSignOut: CheckedContinuation<Void, Never>?
  private var signOutObserver: CheckedContinuation<Void, Never>?
  private(set) var cachedAccountReads = 0
  private(set) var refreshAccountReads = 0

  init(account: NotebookAccount, gists: [Gist], cachesContent: Bool = true) {
    self.account = account
    self.signInAccount = account
    self.notes = gists
    self.cachesContent = cachesContent
  }

  func cachedAccount() throws -> NotebookAccount? {
    cachedAccountReads += 1
    if isSigningOut { throw AccountError.signInInProgress }
    return isSignedOut ? nil : account
  }
  func signIn() -> NotebookAccount {
    isSignedOut = false
    return signInAccount
  }
  func failSignOut(afterLocalCleanup: Bool) {
    failsSignOutAfterCleanup = afterLocalCleanup
  }
  func rejectSignOut() { rejectsSignOut = true }
  func holdSignOut() { holdsSignOut = true }
  func waitForSignOut() async {
    if heldSignOut != nil { return }
    await withCheckedContinuation { signOutObserver = $0 }
  }
  func releaseSignOut() {
    heldSignOut?.resume()
    heldSignOut = nil
    holdsSignOut = false
  }
  func refreshAccount() throws -> NotebookAccount {
    refreshAccountReads += 1
    if isSigningOut { throw AccountError.signInInProgress }
    if shouldFail { throw URLError(.notConnectedToInternet) }
    return account
  }
  func gists(accountID: UUID) -> [Gist] { notes }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) async throws -> Gist {
    readIDs.append(id)
    if id == heldID {
      await withCheckedContinuation { continuation in
        heldRead = continuation
        readObserver?.resume()
        readObserver = nil
      }
    }
    if failingReadIDs.contains(id) { throw URLError(.notConnectedToInternet) }
    guard let gist = notes.first(where: { $0.id == id }) else {
      throw GitHubClientError.missingFile
    }
    return gist
  }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    guard let content = gist.files[filename]?.content else { throw GitHubClientError.missingFile }
    return GistConventions.decodeContent(content)
  }
  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    let store = try draftStore()
    if let draft = document.draft {
      return try await store.draft(id: draft.id, accountID: document.accountID)
    }
    guard let gist = document.gist else { throw DraftError.notFound }
    return try await store.openDraft(
      accountID: document.accountID, githubUserID: 1,
      gistID: gist.id, filename: document.filename, description: gist.description ?? "",
      content: document.text, revision: gist.revision)
  }
  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
    -> DraftSnapshot
  {
    try await draftStore().persist(
      id: draftID, accountID: accountID, text: text, generation: generation)
  }
  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> DraftSnapshot {
    if reason != .manual, !(await shouldPublish()) { throw CancellationError() }
    let store = try draftStore()
    let current = try await store.draft(id: draftID, accountID: accountID)
    if case .conflict = current.state { return current }
    publicationReasons.append(reason)
    try await store.beginAttempt(
      id: draftID, accountID: accountID, content: current.text,
      generation: current.generation, remote: current.baseContent)
    if let index = notes.firstIndex(where: { $0.id == current.gistID }) {
      let gist = notes[index]
      var files = gist.files
      files[current.filename] = GistFile(
        filename: current.filename, language: "Markdown", content: current.text,
        truncated: false, rawURL: nil, size: current.text.utf8.count)
      notes[index] = Gist(
        id: gist.id, description: gist.description, files: files,
        updatedAt: gist.updatedAt, createdAt: gist.createdAt,
        isPublic: gist.isPublic, owner: gist.owner, truncated: gist.truncated, history: gist.history)
    }
    return try await store.acknowledge(
      id: draftID, accountID: accountID, gistID: current.gistID ?? "created-\(draftID)",
      content: current.text, revision: "synthetic-revision", generation: current.generation)
  }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    if case .signOut = action {
      if rejectsSignOut { throw URLError(.notConnectedToInternet) }
      isSigningOut = true
      defer { isSigningOut = false }
      if holdsSignOut {
        await withCheckedContinuation { continuation in
          heldSignOut = continuation
          signOutObserver?.resume()
          signOutObserver = nil
        }
      }
      isSignedOut = true
      if failsSignOutAfterCleanup { throw URLError(.timedOut) }
      return .signedOut
    }
    if case .inspectRemote(let id, let generation) = action {
      let store = try draftStore()
      let draft = try await store.draft(id: id, accountID: accountID)
      let remote = notes.first(where: { $0.id == draft.gistID })?.files[draft.filename]?.content
      return .review(
        try await store.inspectRemoteChange(
          id: id, accountID: accountID, expectedGeneration: generation,
          remote: remote, revision: "synthetic-revision"))
    }
    throw DraftError.notFound
  }
  func localState(accountID: UUID) async throws -> NotebookLocalState {
    localStateReads += 1
    let drafts = try await store?.drafts(accountID: accountID) ?? []
    return NotebookLocalState(library: cached, drafts: drafts)
  }
  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {
    cached = CachedLibrarySnapshot(
      accountID: account.id, owned: cachesContent ? owned : owned.map(metadataOnly),
      starred: cachesContent ? starred : starred.map(metadataOnly),
      preferences: account.preferences)
  }
  private nonisolated func metadataOnly(_ gist: Gist) -> Gist {
    Gist(
      id: gist.id, description: gist.description,
      files: gist.files.mapValues {
        GistFile(
          filename: $0.filename, language: $0.language, content: nil,
          truncated: $0.truncated, rawURL: $0.rawURL, size: $0.size)
      },
      updatedAt: gist.updatedAt, createdAt: gist.createdAt,
      isPublic: gist.isPublic, owner: gist.owner, truncated: gist.truncated, history: gist.history)
  }
  private func draftStore() throws -> DraftStore {
    if let store { return store }
    let new = try DraftStore.open(inMemory: true)
    store = new
    return new
  }
  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    creationCount += 1
    return try await draftStore().createGistDraft(accountID: accountID, githubUserID: 1)
  }
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    todayTargets.append(target)
    let draft = try await draftStore().dailyGistDraft(
      accountID: accountID, githubUserID: 1, target: target)
    return TodayNote(target: target, gist: nil, draft: draft)
  }
  func stageExistingDraft(gistID: String, text: String) async throws -> DraftSnapshot {
    let store = try draftStore()
    let draft = try await store.openDraft(
      accountID: account.id, githubUserID: 1, gistID: gistID, filename: "README.md",
      description: "Recoverable note", content: "Base", revision: "1")
    return try await store.persist(id: draft.id, accountID: account.id, text: text, generation: 8)
  }
  func setGists(_ gists: [Gist]) { notes = gists }
  func setReadFailure(id: String, fails: Bool) {
    if fails { failingReadIDs.insert(id) } else { failingReadIDs.remove(id) }
  }
  func failRequests() { shouldFail = true }
  func setSignInAccount(_ account: NotebookAccount) { signInAccount = account }
  func setAutosaveEnabled(_ enabled: Bool) {
    var metadata = account.preferences.metadata
    metadata["isAutoSaveEnabled"] = .bool(enabled)
    account = NotebookAccount(
      id: account.id, login: account.login, githubUserID: account.githubUserID,
      preferences: .init(metadata: metadata))
  }
  func setSpellingEnabled(_ enabled: Bool) {
    var metadata = account.preferences.metadata
    metadata["isSpellcheckEnabled"] = .bool(enabled)
    account = NotebookAccount(
      id: account.id, login: account.login, githubUserID: account.githubUserID,
      preferences: .init(metadata: metadata))
  }
  func holdRead(id: String) { heldID = id }
  func waitForHeldRead() async {
    if heldRead != nil { return }
    await withCheckedContinuation { readObserver = $0 }
  }
  func releaseRead() {
    heldRead?.resume()
    heldRead = nil
    heldID = nil
  }
}
