import Foundation
import GistPadComments
import GistPadEditor
import GistPadInterface
import GistPadPlatform
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad
@testable import GistPadSync

@MainActor
struct NotebookModelTests {
  @Test func deletedGistCommentControllersCannotReopenOrRecreateTheirDrafts() async throws {
    let gist = try makeGist(id: "a", title: "A conversation")
    let model = NotebookModel(provider: StubNotebookProvider(account: fixtureAccount, gists: [gist]))
    await model.start()
    await model.open(gistID: gist.id)
    let document = try #require(model.loadedDocument)
    let store = NotebookCommentStoreFake()
    let provider = NotebookCommentProvider(notebook: model, store: store)
    let conversation = try await provider.conversation(for: document)
    conversation.updateText("A comment draft to remove")
    #expect(await conversation.flushDraft())
    try await provider.discard(gistID: gist.id, accountID: fixtureAccount.id)
    #expect(try await store.loadDrafts(scope: conversation.scope) == nil)
    #expect(!conversation.isPrepared)
    await #expect(throws: NotebookCommentError.unavailable) {
      try await provider.conversation(for: document)
    }
    #expect(await provider.flushDrafts())
    #expect(try await store.loadDrafts(scope: conversation.scope) == nil)
  }

  @Test func unavailableCommentDraftReadsDoNotBlockDepartureButFailedWritesStillDo() async throws {
    let gist = try makeGist(id: "a", title: "A conversation")
    let model = NotebookModel(provider: StubNotebookProvider(account: fixtureAccount, gists: [gist]))
    await model.start()
    await model.open(gistID: gist.id)
    let document = try #require(model.loadedDocument)
    let store = NotebookCommentStoreFake()
    await store.fail(reads: true, writes: false)
    let provider = NotebookCommentProvider(notebook: model, store: store)
    let conversation = try await provider.conversation(for: document)
    #expect(!conversation.isPrepared)
    #expect(conversation.composer.problem == .localStorage)
    #expect(await provider.flushDrafts())
    #expect(await store.saveCount == 0)
    await store.fail(reads: false, writes: true)
    await conversation.prepare()
    conversation.updateText("Keep my local comment")
    #expect(conversation.isPrepared)
    #expect(!(await provider.flushDrafts()))
    #expect(conversation.draftSaveState == .failed)
    #expect(conversation.activeDraft.text == "Keep my local comment")
    #expect(await store.saveCount == 1)
  }

  @Test func preparingCommentsDoesNotFetchOrRequireEditableNoteSource() async throws {
    let gist = try makeGist(id: "a", title: "A conversation").withCommentCount(2)
    let model = NotebookModel(provider: StubNotebookProvider(account: fixtureAccount, gists: [gist]))
    await model.start()
    await model.open(gistID: gist.id)
    var document = try #require(model.loadedDocument)
    document.chrome.access = .readOnly
    let provider = NotebookCommentProvider(notebook: model, store: NotebookCommentStoreFake())
    let conversation = try await provider.conversation(for: document)
    #expect(conversation.isPrepared)
    #expect(conversation.composer.canEdit)
    #expect(conversation.knownTotal == 2)
    #expect(conversation.comments == nil)
    #expect(conversation.loadFailure == nil)
    #expect(try await provider.conversation(for: document) === conversation)
  }

  @Test func commentTotalsUpdateEveryGistProjectionWithoutChangingTheDocument() async throws {
    let gist = try makeGist(
      id: "a", title: "A conversation", content: "Find this passage",
      additionalFiles: ["Other.md": "Find another passage"]).withCommentCount(2)
    let other = try makeGist(id: "b", title: "Another note").withCommentCount(3)
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [gist, other], starred: [gist])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: gist.id)
    let document = try #require(model.loadedDocument)
    model.recordCommentCount(accountID: fixtureAccount.id, gistID: gist.id, total: 7)
    #expect(model.library.snapshot.notes.first(where: { $0.gistID == gist.id })?.commentCount == 7)
    #expect(model.library.snapshot.notes.first(where: { $0.gistID == other.id })?.commentCount == 3)
    #expect(model.cachedLibrary?.owned.first(where: { $0.id == gist.id })?.commentCount == 7)
    #expect(model.cachedLibrary?.starred.first(where: { $0.id == gist.id })?.commentCount == 7)
    #expect(model.loadedDocument?.id == document.id)
    #expect(model.loadedDocument?.text == document.text)
    #expect(model.loadedDocument?.gist?.commentCount == 7)
    #expect(model.loadedDocument?.chrome.commentCount == 7)
    model.library.query = "Find"
    await model.search()
    #expect(model.library.matchingNotes.count == 2)
    #expect(model.library.matchingNotes.allSatisfy { $0.commentCount == 7 })
    model.recordCommentCount(accountID: fixtureAccount.id, gistID: gist.id, total: 8)
    #expect(model.library.matchingNotes.allSatisfy { $0.commentCount == 8 })
    #expect(model.cachedLibrary?.gists.first(where: { $0.id == gist.id })?.commentCount == 8)
  }

  @Test func staleAccountCommentTotalsCannotChangeTheCurrentNotebook() async throws {
    let gist = try makeGist(id: "a", title: "A conversation").withCommentCount(2)
    let model = NotebookModel(provider: StubNotebookProvider(account: fixtureAccount, gists: [gist]))
    await model.start()
    model.recordCommentCount(accountID: UUID(), gistID: gist.id, total: 99)
    #expect(model.cachedLibrary?.gists.first?.commentCount == 2)
    #expect(model.library.snapshot.notes.first(where: { $0.id == gist.id })?.commentCount == 2)
  }

  @Test func reviewIsOwnedByTheOpenSessionAndClosedHandlesCannotReviveOnReopen() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "A reviewed note")])
    let notebook = NotebookModel(provider: provider)
    await notebook.start()
    await notebook.open(gistID: "a")
    let document = try #require(notebook.loadedDocument)
    let draft = try await notebook.openDraft(for: document)
    let controller = NotebookSessionController(
      document: document, draft: draft, notebook: notebook)
    let review = controller.reviewState()
    #expect(controller.review === review)
    #expect(controller.reviewState() === review)
    #expect(!review.hasReview)
    #expect(!review.isStale)
    controller.clearReview()
    #expect(controller.review == nil)
    #expect(review.isStale)
    #expect(!review.hasReview)
    let reopened = controller.reviewState()
    #expect(reopened !== review)
    #expect(!reopened.isStale)
    #expect(review.isStale)
    #expect(controller.session.text == draft.text)
    #expect(controller.session.generation == draft.generation)
  }

  @Test func libraryDeleteResolvesOwnedGistsAndSearchFilesButNeverLocalOrRecoveryRows() async throws {
    let owned = try makeGist(
      id: "a", title: "An owned notebook", content: "Find this thought",
      additionalFiles: ["日本語.md": "Find this other thought"])
    let shared = try makeGist(id: "shared", title: "A friend's notebook", owner: "a-friend")
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [owned], starred: [shared])
    let recovery = try await provider.stageExistingDraft(gistID: "missing", text: "Find my recovery")
    let local = try await provider.createDraft(accountID: fixtureAccount.id)
    _ = try await provider.persist(
      draftID: local.id, accountID: local.accountID, text: "Find my local draft", generation: 1)
    let model = NotebookModel(provider: provider)
    await model.start()
    let target = try #require(model.libraryDeletionTarget(for: "a"))
    #expect(target.id == "a")
    #expect(target.title == owned.displayName)
    #expect(target.accountID == fixtureAccount.id)
    #expect(model.library.snapshot.notes.first(where: { $0.id == "a" })?.canDeleteFromGitHub == true)
    for id in [local.id.uuidString, recovery.id.uuidString, "missing", "unknown", "shared"] {
      #expect(model.libraryDeletionTarget(for: id) == nil)
      #expect(model.library.snapshot.notes.first(where: { $0.id == id })?.canDeleteFromGitHub != true)
    }
    model.library.query = "Find"
    await model.search()
    for note in model.library.matchingNotes {
      if model.searchTargets[note.id]?.gistID == owned.id {
        #expect(note.canDeleteFromGitHub)
        #expect(model.libraryDeletionTarget(for: note.id)?.id == owned.id)
        #expect(model.libraryDeletionTarget(for: note.id)?.title == owned.displayName)
      } else {
        #expect(!note.canDeleteFromGitHub)
        #expect(model.libraryDeletionTarget(for: note.id) == nil)
      }
    }
    #expect(model.library.matchingNotes.filter(\.canDeleteFromGitHub).count == 2)
    #expect(await provider.deletedIDs.isEmpty)
    #expect(model.localDrafts.first(where: { $0.id == local.id })?.text == "Find my local draft")
    #expect(model.localDrafts.first(where: { $0.id == recovery.id })?.text == "Find my recovery")
  }

  @Test func deletingALibraryGistRemovesItsRowAndQuietlyOpensToday() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "A published note")])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    _ = try await model.openDraft(for: #require(model.loadedDocument))
    let target = try #require(model.libraryDeletionTarget(for: "a"))
    #expect(await provider.deletedIDs.isEmpty)
    _ = try await model.perform(.delete(gistID: target.id))
    #expect(await provider.deletedIDs == ["a"])
    #expect(model.isTodaySelected)
    #expect(model.loadedDocument?.opensForEditing == false)
    #expect(model.library.selectedNoteID == model.loadedDocument?.rowID)
    #expect(model.library.snapshot.notes.allSatisfy { $0.id != "a" })
    #expect(model.libraryDeletionTarget(for: "a") == nil)
  }

  @Test func deletingAnEditedPublishedGistPurgesItsDraftHistoryAndSearchResult() async throws {
    let title = "A published and edited note"
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: title)])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "a")
    let draft = try await model.openDraft(for: #require(model.loadedDocument))
    _ = try await model.persist(
      draftID: draft.id, accountID: draft.accountID, text: "An accepted edit", generation: 1)
    _ = try await model.publish(draftID: draft.id, accountID: draft.accountID)
    #expect(try await provider.recoveryCount(draftID: draft.id) == 1)
    model.library.query = "accepted edit"
    await model.search()
    #expect(model.library.matchingNotes.count == 1)
    _ = try await model.perform(.delete(gistID: "a"))
    #expect(await provider.deletedIDs == ["a"])
    #expect(model.library.collectionGistCount == 0)
    #expect(model.library.matchingNotes.isEmpty)
    #expect(model.localDrafts.count == 1)
    #expect(model.localDrafts.first?.isDiscardableBlank == true)
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.allSatisfy {
      $0.gistID != "a" && $0.isDiscardableBlank
    })
    await #expect(throws: DraftError.notFound) {
      try await provider.recoveryCount(draftID: draft.id)
    }
    await model.refresh()
    await model.search()
    #expect(model.library.matchingNotes.isEmpty)
    #expect(model.library.snapshot.notes.allSatisfy { $0.isDailyNote })
    #expect(model.isTodaySelected)
    #expect(model.loadedDocument?.opensForEditing == false)
    let restarted = NotebookModel(provider: provider)
    await restarted.start()
    restarted.library.query = "accepted edit"
    await restarted.search()
    #expect(restarted.localDrafts.count == 1)
    #expect(restarted.localDrafts.first?.isDiscardableBlank == true)
    #expect(restarted.library.matchingNotes.isEmpty)
    #expect(restarted.library.snapshot.notes.allSatisfy { $0.isDailyNote })
    #expect(restarted.isTodaySelected)
  }

  @Test(arguments: [false, true])
  func aStaleListAfterDeletionCannotRestoreTheGistOrItsCachedContent(daily: Bool) async throws {
    let deleted = try makeGist(
      id: "a", title: daily ? GistConventions.dailyNotesDescription : "A published note",
      content: "Deleted source", filename: daily ? GistConventions.todayFilename() : "README.md")
    let kept = try makeGist(id: "b", title: "Keep this note")
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [deleted, kept], starred: [deleted])
    let selections = NotebookSelectionStore()
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    _ = try await model.perform(.delete(gistID: deleted.id))
    await provider.setListResponses(owned: [deleted, kept], starred: [deleted])
    await model.refresh()
    for collection in LibraryCollection.allCases {
      model.library.collection = collection
      #expect(model.library.matchingNotes.allSatisfy { $0.id != deleted.id })
    }
    #expect(model.library.pinnedNotes.allSatisfy { $0.id != deleted.id })
    #expect(model.cachedLibrary?.gists.map(\.id) == [kept.id])
    #expect(try await provider.localState(accountID: fixtureAccount.id).library?.gists.map(\.id)
      == [kept.id])
    #expect(model.deletedGistIDs.contains(deleted.id))
    #expect(selections.deletedGistIDs(accountID: fixtureAccount.id).contains(deleted.id))
    if daily {
      #expect(model.library.today.availability == .existing)
      #expect(model.loadedDocument?.draft?.gistID == nil)
      #expect(model.loadedDocument?.draft?.isDiscardableBlank == true)
    }

    let restarted = NotebookModel(provider: provider, selections: selections)
    await restarted.start()
    #expect(restarted.cachedLibrary?.gists.map(\.id) == [kept.id])
    #expect(restarted.library.snapshot.notes.allSatisfy { $0.id != deleted.id })
    await provider.setListResponses(owned: [kept], starred: [])
    await restarted.refresh()
    #expect(!restarted.deletedGistIDs.contains(deleted.id))
    #expect(!selections.deletedGistIDs(accountID: fixtureAccount.id).contains(deleted.id))
  }

  @Test func aRefreshAlreadyInFlightCannotResurrectASuccessfullyDeletedGist() async throws {
    let deleted = try makeGist(id: "a", title: "Delete this published note")
    let kept = try makeGist(id: "b", title: "Keep this note")
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [deleted, kept], starred: [deleted])
    let model = NotebookModel(provider: provider)
    await model.start()
    await provider.holdLibraryRead()
    let refresh = Task { await model.refresh() }
    await provider.waitForHeldLibraryRead()
    _ = try await model.perform(.delete(gistID: deleted.id))
    #expect(model.library.snapshot.notes.filter { !$0.isDailyNote }.map(\.id) == [kept.id])
    await provider.releaseLibraryRead()
    await refresh.value
    #expect(model.library.snapshot.notes.filter { !$0.isDailyNote }.map(\.id) == [kept.id])
    #expect(model.cachedLibrary?.gists.map(\.id) == [kept.id])
    #expect(try await provider.localState(accountID: fixtureAccount.id).library?.gists.map(\.id)
      == [kept.id])
    #expect(model.deletedGistIDs.contains(deleted.id))
    #expect(!model.isRefreshingRemote)
    await model.refresh()
    #expect(!model.deletedGistIDs.contains(deleted.id))
  }

  @Test func persistedDeletionsFilterAnOfflineCacheWithoutChangingAnotherAccount() async throws {
    let suite = "NotebookDeletion-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let otherAccount = UUID()
    let selections = NotebookSelectionStore(defaults: defaults)
    selections.markDeleted(gistID: "a", accountID: fixtureAccount.id)
    selections.markDeleted(gistID: "a", accountID: otherAccount)
    let deleted = try makeGist(id: "a", title: "Deleted note")
    let kept = try makeGist(id: "b", title: "Kept note")
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [deleted, kept])
    await provider.cacheLibrary(owned: [deleted, kept], starred: [deleted], account: fixtureAccount)
    await provider.failRequests()
    let restored = NotebookSelectionStore(defaults: defaults)
    let model = NotebookModel(provider: provider, selections: restored, remoteReadRetryDelays: [])
    await model.start()
    #expect(model.library.snapshot.notes.filter { !$0.isDailyNote }.map(\.id) == [kept.id])
    #expect(model.cachedLibrary?.gists.map(\.id) == [kept.id])
    #expect(try await provider.localState(accountID: fixtureAccount.id).library?.gists.map(\.id)
      == [kept.id])
    #expect(restored.deletedGistIDs(accountID: fixtureAccount.id) == ["a"])
    #expect(restored.deletedGistIDs(accountID: otherAccount) == ["a"])
    restored.confirmDeleted(gistIDs: ["a"], accountID: fixtureAccount.id)
    #expect(restored.deletedGistIDs(accountID: fixtureAccount.id).isEmpty)
    #expect(restored.deletedGistIDs(accountID: otherAccount) == ["a"])
    #expect(NotebookModel.librarySnapshot(
      owned: [deleted, kept], starred: [deleted], account: fixtureAccount,
      excluding: ["a"]).notes.map(\.id) == [kept.id])
  }

  @Test(arguments: [Optional<Bool>.none, false, true])
  func sourceUsesTheSavedFrontMatterPreferenceWithoutChangingTheDraft(shown: Bool?) async throws {
    let prefix = "---\nedit:\n  instructions: Preserve source bytes\n---\n\n"
    let source = prefix + "# Content\n\nA retained thought."
    var metadata = fixtureAccount.preferences.metadata
    if let shown { metadata["showFrontmatter"] = .bool(shown) }
    let account = NotebookAccount(
      id: fixtureAccount.id, login: fixtureAccount.login, githubUserID: fixtureAccount.githubUserID,
      preferences: .init(metadata: metadata))
    let provider = StubNotebookProvider(
      account: account, gists: [try makeGist(id: "frontmatter", title: "Content", content: source)])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.open(gistID: "frontmatter")
    let document = try #require(model.loadedDocument)
    let draft = try await model.openDraft(for: document)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    #expect(controller.session.showsFrontMatter == (shown ?? false))
    #expect(controller.session.contentStart == (shown == true ? 0 : prefix.utf16.count))
    #expect(
      controller.session.selection
        == .init(
          location: shown == true ? 0 : prefix.utf16.count, length: 0))
    #expect(controller.session.text.utf8.elementsEqual(source.utf8))
    #expect(controller.session.textView.text.utf8.elementsEqual(source.utf8))
    #expect(controller.session.generation == draft.generation)
    #expect(controller.session.textView.undoManager?.canUndo != true)
    let identity = controller.session.viewIdentity
    let view = controller.session.textView
    await provider.setShowsFrontMatter(!(shown ?? false))
    await model.refresh()
    try await controller.refreshMetadata()
    #expect(controller.session.showsFrontMatter == !(shown ?? false))
    #expect(controller.session.contentStart == (shown == true ? prefix.utf16.count : 0))
    #expect(controller.session.viewIdentity == identity)
    #expect(controller.session.textView === view)
    #expect(controller.session.text.utf8.elementsEqual(source.utf8))
    #expect(controller.session.generation == draft.generation)
    #expect(controller.session.textView.undoManager?.canUndo != true)
  }

  @Test(arguments: [false, true], [false, true])
  func launchDiscardsAnAbandonedBlankDraftEvenWhenItWasRemembered(
    remembered: Bool, offline: Bool
  ) async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let blank = try await provider.createDraft(accountID: fixtureAccount.id)
    let kept = try await provider.createDraft(accountID: fixtureAccount.id)
    let text = "Keep e\u{301}\r\n日本語 👩🏽‍💻"
    _ = try await provider.persist(
      draftID: kept.id, accountID: kept.accountID, text: text, generation: 1)
    let selections = NotebookSelectionStore()
    if remembered {
      try selections.save(
        .init(gistID: nil, filename: blank.filename, draftID: blank.id),
        accountID: fixtureAccount.id)
    }
    if offline { await provider.failRequests() }
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    let today = try #require(model.loadedDocument?.draft)
    #expect(Set(model.localDrafts.map(\.id)) == [kept.id, today.id])
    #expect(Set(model.library.snapshot.notes.map(\.id)) == [kept.id.uuidString, today.id.uuidString])
    #expect(!model.localDrafts.contains { $0.id == blank.id })
    #expect(model.isTodaySelected)
    #expect(today.isDiscardableBlank)
    #expect(model.documentError == nil)
    #expect(try selections.selection(accountID: fixtureAccount.id)?.draftID == today.id)
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.first(where: {
      $0.id == kept.id
    })?.text.utf8
      .elementsEqual(text.utf8) == true)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func refreshingTheLibraryNeverDiscardsTheCurrentlyOpenBlankDraft() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    let today = try #require(model.loadedDocument?.draft)
    await model.createNote()
    let blank = try #require(model.loadedDocument?.draft)
    await model.refresh()
    #expect(model.loadedDocument?.draft?.id == blank.id)
    #expect(model.library.selectedNoteID == blank.id.uuidString)
    #expect(Set(model.localDrafts.map(\.id)) == [today.id, blank.id])
    #expect(try await !model.discardBlankDraft(blank))
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.contains {
      $0.id == blank.id
    })
  }

  @Test func anEmptyCurrentSessionIsKeptUntilItActuallyLeaves() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.createNote()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    #expect(await !controller.finishLeavingNote())
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.contains {
      $0.id == draft.id
    })
    #expect(await provider.publicationReasons.isEmpty)
    model.showLibrary()
    #expect(await controller.finishLeavingNote())
    #expect(!controller.hasUnpublishedChanges)
    #expect(!controller.canMutate)
    #expect(await !controller.finishLeavingNote())
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.allSatisfy {
      $0.id != draft.id && $0.isDiscardableBlank
    })
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func leavingAfterErasingANewNoteDiscardsOnlyItsPersistedBlankGeneration() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    await model.createNote()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    for text in ["A thought", " \t\r\n"] {
      controller.session.textView.text = text
      controller.session.textViewDidChange(controller.session.textView)
    }
    model.showLibrary()
    #expect(await controller.finishLeavingNote())
    #expect(controller.session.generation == 2)
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.allSatisfy {
      $0.id != draft.id && $0.isDiscardableBlank
    })
    #expect(await provider.publicationReasons.isEmpty)
  }

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
    try selectionStore.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
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

  @Test func coldStartEnsuresTodayQuietlyWithoutPublishingAnUntouchedTemplate() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    #expect(document.filename == DailyNoteTarget().filename)
    #expect(!document.opensForEditing)
    #expect(model.isTodaySelected)
    #expect(draft.isDiscardableBlank)
    let controller = NotebookSessionController(
      document: document, draft: draft, notebook: model, autosaveDelay: .milliseconds(1))
    #expect(!controller.hasUnpublishedChanges)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    await controller.publish(reason: .background)
    #expect(await provider.publicationReasons.isEmpty)
    await model.startToday()
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(model.loadedDocument?.opensForEditing == true)
    #expect(await provider.todayTargets.count == 1)
    controller.adoptPresentation(try #require(model.loadedDocument))
    controller.requestCreationFocus()
    #expect(controller.mode == .source)
    controller.mode = .reading
    controller.requestCreationFocus()
    #expect(controller.mode == .reading, "A render does not repeat the same editing request.")
    await model.startToday()
    controller.adoptPresentation(try #require(model.loadedDocument))
    controller.requestCreationFocus()
    #expect(controller.mode == .source, "A fresh Today action focuses the retained editor again.")
  }

  @Test func failedAutomaticTodayUsesTheFailedOpenRetryWithoutStealingFocus() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    await provider.failToday(true)
    let model = NotebookModel(provider: provider)
    await model.start()
    let failure = try #require(model.failedOpen)
    #expect(failure.todayTarget == DailyNoteTarget())
    #expect(!failure.focusesEditor)
    #expect(model.documentError == nil)
    #expect(model.presentedDocument == nil)
    await provider.failToday(false)
    await model.retryFailedOpen()
    #expect(model.failedOpen == nil)
    #expect(model.loadedDocument?.filename == failure.todayTarget?.filename)
    #expect(model.loadedDocument?.opensForEditing == false)
    #expect(await provider.todayTargets.count == 2)
  }

  @Test(arguments: [false, true])
  func anUntouchedDailyTemplateNeedsNoRemoteInspection(bound: Bool) async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    let store = try DraftStore.open(inMemory: true)
    let target = DailyNoteTarget()
    let draft = if bound {
      try await store.newFileDraft(
        accountID: fixtureAccount.id, githubUserID: 1, gistID: "daily",
        filename: target.filename, description: GistConventions.dailyNotesDescription,
        text: GistConventions.dailyContent(template: nil, dateFilename: target.filename))
    } else {
      try await store.dailyGistDraft(
        accountID: fixtureAccount.id, githubUserID: 1, target: target)
    }
    let controller = NotebookSessionController(
      document: NotebookDocument(draft: draft), draft: draft, notebook: model)
    await controller.inspectRemoteChanges()
    #expect(await provider.inspectionCount == 0)
    #expect(!controller.isInspectingRemote)
    #expect(controller.remoteInspectionStatus == .idle)
    #expect(controller.remoteInspectionError == nil)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func leavingAnUntouchedAutomaticTodayDiscardsItWithoutPublishing() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let model = NotebookModel(provider: provider)
    await model.start()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    await model.createNote()
    #expect(await controller.finishLeavingNote())
    #expect(!model.localDrafts.contains(where: { $0.id == draft.id }))
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func aSlowAutomaticTodayDoesNotBlockOrReplaceAnExplicitNewNote() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    await provider.holdToday()
    let model = NotebookModel(provider: provider)
    let start = Task { await model.start() }
    await provider.waitForToday()
    #expect(model.openingTitle == "Today")
    await model.createNote()
    let chosen = try #require(model.loadedDocument)
    #expect(chosen.filename == "README.md")
    #expect(chosen.opensForEditing)
    await provider.releaseToday()
    await start.value
    #expect(model.loadedDocument?.id == chosen.id)
    #expect(!model.isCreating)
    #expect(await provider.creationCount == 1)
    #expect(await provider.publicationReasons.isEmpty)
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
    #expect(missing.library.today.availability == .existing)
    #expect(missing.library.today.excerpt == nil)
    #expect(missing.loadedDocument?.draft?.isDiscardableBlank == true)
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
    #expect(model.library.today.excerpt == nil, "A date-only template is not excerpt prose.")
    await model.createNote()
    #expect(model.loadedDocument?.draft?.id != daily.id)
    await model.startToday()
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
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
    let model = NotebookModel(provider: provider, selections: selections)
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
    #expect(note.canDeleteFromGitHub)
    #expect(note.isStarred)
    #expect(note.isPinned)
    #expect(note.isSecret)
    #expect(note.tagIDs == ["ideas"])
    #expect(note.fileCount == 1)
    #expect(snapshot.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
    #expect(snapshot.notes.first { $0.id == "b" }?.isOwned == false)
    #expect(snapshot.notes.first { $0.id == "b" }?.canDeleteFromGitHub == false)
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

  @Test func durableEditsRefreshCleanDefaultFileExcerptsWithoutUsingAnotherFile() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "a", title: "A useful note", content: "Cached source",
          additionalFiles: ["Ideas.md": "Another file"])
      ])
    let primary = try await provider.stageExistingDraft(
      gistID: "a", text: "# A useful note\n\nAn earlier thought.")
    let model = NotebookModel(provider: provider)
    await model.start()
    _ = try await model.persist(
      draftID: primary.id, accountID: fixtureAccount.id,
      text: "---\nprivate: metadata\n---\n\n# A useful note\n\n- [x] Keep **this thought**.",
      generation: primary.generation + 1)
    #expect(model.library.snapshot.notes.first(where: { $0.id == "a" })?.excerpt == "Keep this thought.")
    await model.open(gistID: "a", filename: "Ideas.md")
    let secondaryDocument = try #require(model.loadedDocument)
    let secondary = try await provider.openDraft(for: secondaryDocument)
    _ = try await model.persist(
      draftID: secondary.id, accountID: fixtureAccount.id,
      text: "# Ideas\n\nThis is not the default file.", generation: secondary.generation + 1)
    #expect(model.library.snapshot.notes.first(where: { $0.id == "a" })?.excerpt == "Keep this thought.")
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
    #expect(model.library.visibleSelectedNoteID == nil)
    #expect(model.library.selectedNoteID == "a")
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
    #expect(model.localDrafts.contains { $0.id == draft.id })
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
    #expect(model.library.snapshot.notes.filter { !$0.isDailyNote }.count == 1)
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

  @Test func anExplicitTodayActionPinsTheRequestedDayWithoutAnInterstitial() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount, gists: [try makeGist(id: "a", title: "Last chosen")])
    let selections = NotebookSelectionStore()
    try selections.save(
      .init(gistID: "a", filename: "README.md", draftID: nil), accountID: fixtureAccount.id)
    let model = NotebookModel(provider: provider, selections: selections)
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "a")
    #expect(await provider.creationCount == 0)
    #expect(await provider.todayTargets.isEmpty)
    let target = DailyNoteTarget(
      date: Date(timeIntervalSince1970: 1_790_208_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    await model.startToday(target: target)
    #expect(await provider.todayTargets == [target])
    #expect(model.loadedDocument?.draft?.filename == target.filename)
    #expect(model.loadedDocument?.opensForEditing == true)
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
    #expect(await provider.todayTargets.count == 1)
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
    #expect(model.loadedDocument?.accountID == other.id)
    #expect(model.isTodaySelected)
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
    #expect(row.dailyDate == DailyNotesIndex.parseDateFilename(filename))
    #expect(model.library.dailyNoteCount == 1)
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(model.library.today.excerpt == "One\nTwo")
    await model.openRow(id: row.id)
    #expect(model.loadedDocument?.filename == filename)
    #expect(model.library.selectedNoteID == row.id)
  }
}

@Suite(.serialized)
@MainActor
struct NotebookNavigationHostTests {
  @Test(arguments: [false, true])
  func reopeningPreviewThenEditKeepsTheSourceGlyphsOnScreen(startsInPreview: Bool) async throws {
    let source = """
      ---
      edit:
        commands:
          progress: Update a reading entry
        instructions: >-
          Preserve the reading list's existing sections and entries.
      ---

      # A visible reading list

      ## In progress

      """
      + (1...300).map { "\($0). A retained reading entry \($0)\n" }.joined()
      + "\n## Another section\n\nAn exact final source line."
    let other = "# Another note\n\nA different retained source."
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [
        try makeGist(
          id: "reading", title: "Reading list", content: source,
          additionalFiles: ["Calendar.md": "# A second file"]),
        try makeGist(id: "other", title: "Another note", content: other),
      ])
    let host = try await NavigationHost(
      provider: provider, sizeClass: .compact, initialMode: startsInPreview ? .reading : .source)
    defer { await host.close() }
    host.window.overrideUserInterfaceStyle = .dark
    var retained: UITextView?
    var checkedWidthChange = false
    for id in ["reading", "other", "reading", "other", "reading"] {
      let text = id == "reading" ? source : other
      host.model.library.selectedNoteID = id
      try await host.waitUntil {
        host.model.presentedDocument?.gist?.id == id && host.editor(text: text) != nil
          && host.descendants.contains { $0 is UISegmentedControl }
      }
      let editor = try #require(host.editor(text: text))
      if id == "reading" {
        if let retained { #expect(editor === retained) } else { retained = editor }
      }
      try await Task.sleep(for: .milliseconds(450))
      Attachment.record(
        UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
          host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }, named: "initial-source-\(id).png", as: .png)
      if !checkedWidthChange {
        let compactWidth = host.window.frame.width
        host.window.traitOverrides.horizontalSizeClass = .regular
        host.window.frame.size.width = 1180
        try await host.waitUntil {
          host.descendants.compactMap { $0 as? UISegmentedControl }.last?.numberOfSegments == 3
        }
        host.layout.select(.split)
        try await Task.sleep(for: .milliseconds(450))
        try host.expectSourceInk(editor, named: "wide-split-source")
        host.window.traitOverrides.horizontalSizeClass = .compact
        host.window.frame.size.width = compactWidth
        try await host.waitUntil {
          host.descendants.compactMap { $0 as? UISegmentedControl }.last?.numberOfSegments == 2
        }
        host.layout.select(startsInPreview ? .reading : .source)
        checkedWidthChange = true
      }
      for mode in [1, 0, 1, 0] {
        let picker = try #require(host.descendants.compactMap { $0 as? UISegmentedControl }.last)
        try #require(picker.numberOfSegments == 2)
        picker.selectedSegmentIndex = mode
        picker.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(450))
        if mode == 1 {
          let preview = try #require(host.descendants.compactMap { $0 as? WKWebView }.first)
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          var rendered = false
          repeat {
            rendered = try await preview.callAsyncJavaScript(
              "return document.body.innerText.includes('retained');",
              arguments: [:], in: nil, contentWorld: .page) as? Bool == true
            if !rendered { try await Task.sleep(for: .milliseconds(20)) }
          } while !rendered && ContinuousClock.now < deadline
          #expect(rendered == true)
        } else {
          try await host.waitForKeyboard(visible: true)
          host.window.layoutIfNeeded()
          editor.layoutIfNeeded()
          let position = try #require(editor.selectedTextRange?.end)
          let glyph = editor.convert(editor.caretRect(for: position), to: host.window)
          let bar = try #require(host.descendants.compactMap { $0 as? UINavigationBar }.last)
          let top = bar.convert(bar.bounds, to: host.window).maxY
          Attachment.record(
            """
            note: \(id), editor: \(editor.convert(editor.bounds, to: host.window))
            offset: \(editor.contentOffset), size: \(editor.contentSize)
            insets: \(editor.adjustedContentInset), text inset: \(editor.textContainerInset)
            selected glyph: \(glyph), navigation bottom: \(top), selection: \(editor.selectedRange)
            mounted: \(editor.window === host.window), visible: \(host.isVisible(editor))
            """, named: "source-mount-\(id).txt")
          #expect(editor.window === host.window)
          #expect(host.isVisible(editor))
          #expect(glyph.height > 0)
          let contentStart = MarkdownFrontMatter.contentStart(in: text)
          #expect(editor.selectedRange == NSRange(location: contentStart, length: 0))
          #expect(glyph.minY >= top - 1)
          #expect(glyph.minY < top + 40)
          #expect(glyph.maxY < editor.convert(editor.bounds, to: host.window).maxY
            - editor.adjustedContentInset.bottom + 1)
          #expect(editor.text.utf8.elementsEqual(text.utf8))
          Attachment.record(
            UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
              host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
            }, named: "selected-source-\(id).png", as: .png)
          editor.resignFirstResponder()
          try await host.waitForKeyboard(visible: false)
          try await Task.sleep(for: .milliseconds(150))
          try host.expectSourceInk(editor, named: "dismissed-source-\(id)")
        }
      }
      host.setScenePhase(.background)
      try await Task.sleep(for: .milliseconds(150))
      host.setScenePhase(.active)
      try await Task.sleep(for: .milliseconds(450))
      try host.expectSourceInk(editor, named: "foreground-source-\(id)")
      host.routes.submit(.library)
      try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    }
  }

  @Test(arguments: [false, true])
  func leavingANewBlankNoteDiscardsItsDraftWithoutPublishing(autosave: Bool) async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let host = try await NavigationHost(
      provider: provider, autosave: autosave, sizeClass: .compact)
    defer { await host.close() }
    await host.model.createNote()
    let blank = try #require(host.model.loadedDocument?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    #expect(host.model.localDrafts.filter {
      $0.description != GistConventions.dailyNotesDescription
    }.map(\.id) == [blank.id])
    host.routes.submit(.library)
    try await host.waitUntil {
      host.routes.pending == nil && host.isLibraryVisible
        && !host.model.localDrafts.contains { $0.id == blank.id } && host.model.isTodaySelected
        && host.model.loadedDocument?.draft?.isDiscardableBlank == true
    }
    let today = try #require(host.model.loadedDocument?.draft)
    #expect(today.isDiscardableBlank)
    #expect(host.model.loadedDocument?.opensForEditing == false)
    #expect(!host.model.library.snapshot.notes.contains { $0.id == blank.id.uuidString })
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.map(\.id) == [today.id])
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func leavingANewNoteAfterTypingKeepsItsDurableContent() async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let host = try await NavigationHost(provider: provider, sizeClass: .compact)
    defer { await host.close() }
    await host.model.createNote()
    let draft = try #require(host.model.loadedDocument?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    let editor = try #require(host.editor(text: ""))
    let text = "A thought worth keeping 👩🏽‍💻"
    editor.insertText(text)
    host.routes.submit(.library)
    try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    try await host.waitUntil { host.model.localDrafts.first(where: { $0.id == draft.id })?.text == text }
    #expect(try await provider.localState(accountID: fixtureAccount.id).drafts.first(where: {
      $0.id == draft.id
    })?.text == text)
    #expect(await provider.publicationReasons.isEmpty)
  }

  @Test func selectingAnotherNoteDiscardsTheOldBlankButKeepsTheNewSelection() async throws {
    let provider = StubNotebookProvider(
      account: fixtureAccount,
      gists: [try makeGist(id: "kept", title: "Kept", content: "A real note")])
    let host = try await NavigationHost(provider: provider, sizeClass: .compact)
    defer { await host.close() }
    await host.model.createNote()
    let blank = try #require(host.model.loadedDocument?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    host.routes.submit(.note(gistID: "kept", filename: nil, shared: false))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "A real note") != nil
        && !host.model.localDrafts.contains { $0.id == blank.id }
    }
    #expect(host.model.library.selectedNoteID == "kept")
    #expect(host.model.loadedDocument?.gist?.id == "kept")
    #expect(try await !provider.localState(accountID: fixtureAccount.id).drafts.contains {
      $0.id == blank.id
    })
    #expect(await provider.publicationReasons.isEmpty)
  }

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
    try await host.waitUntil { host.model.localDrafts.first(where: { $0.gistID == "a" })?.generation == 1 }
    host.routes.submit(.library)
    try await host.waitUntil(timeout: .seconds(1)) {
      host.routes.pending == nil
        && host.model.localDrafts.first(where: { $0.gistID == "a" })?.state == .savedToGitHub
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
    try await host.waitUntil { host.model.localDrafts.first(where: { $0.gistID == "a" })?.generation == 1 }
    host.routes.submit(.library)
    try await host.waitUntil { host.routes.pending == nil && host.isLibraryVisible }
    #expect(host.model.library.selectedNoteID == nil)
    #expect(host.model.localDrafts.first(where: { $0.gistID == "a" })?.text == "Local Current source")
    #expect(host.model.localDrafts.first(where: { $0.gistID == "a" })?.state == .savedLocally)
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
  func libraryLinksKeepQuietTodayUnpushedAndUnfocused(address: String) async throws {
    let provider = StubNotebookProvider(account: fixtureAccount, gists: [])
    let routes = NotebookRouteInbox()
    routes.submit(try NotebookRoute(url: #require(URL(string: address))))
    let host = try await NavigationHost(provider: provider, routes: routes, sizeClass: .compact)
    defer { await host.close() }
    try await host.waitUntil { routes.pending == nil && host.isLibraryVisible }
    try await Task.sleep(for: .milliseconds(300))
    #expect(host.isLibraryVisible)
    #expect(host.model.loadedDocument?.filename == DailyNoteTarget().filename)
    #expect(host.model.loadedDocument?.opensForEditing == false)
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
    try await host.waitUntil {
      !host.model.isOpeningDocument && host.model.isTodaySelected
        && host.model.loadedDocument?.opensForEditing == false && host.isLibraryVisible
    }
    #expect(host.model.loadedDocument?.filename == DailyNoteTarget().filename)
    #expect(host.model.loadedDocument?.opensForEditing == false)
    #expect(host.model.presentedDocument?.gist?.id != "a")
    #expect(host.isLibraryVisible)
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
    try await host.waitUntil { host.model.localDrafts.first(where: { $0.gistID == "a" })?.generation == 1 }
    await provider.holdRead(id: "b")
    defer { Task { await provider.releaseRead() } }
    #expect(!host.model.beginOpeningRow(id: "b"))
    let opening = Task { await host.model.openRow(id: "b") }
    await provider.waitForHeldRead()
    try await host.waitUntil(timeout: .seconds(1)) {
      host.model.localDrafts.first(where: { $0.gistID == "a" })?.state == .savedToGitHub
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
    try #require(first.becomeFirstResponder())
    try await host.waitForKeyboard(visible: true)
    first.resignFirstResponder()
    try await host.waitForKeyboard(visible: false)
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
  private let controller: UIHostingController<NavigationHostRoot>
  private let suite: String
  private let previousWindow: UIWindow?

  init(
    provider: StubNotebookProvider, autosave: Bool = false,
    routes: NotebookRouteInbox = NotebookRouteInbox(),
    sizeClass: UIUserInterfaceSizeClass? = nil,
    columnVisibility: NavigationSplitViewVisibility = .all,
    restoredSelection: NotebookSelection? = nil,
    initialMode: NoteMode = .source
  ) async throws {
    self.routes = routes
    await provider.setAutosaveEnabled(autosave)
    suite = "NotebookNavigationHost-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    layout = NotebookLayoutPreferences(defaults: defaults)
    layout.select(initialMode)
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
    controller = UIHostingController(
      rootView: NavigationHostRoot(
        notebook: model, layout: layout, routes: routes, columnVisibility: columnVisibility))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    try await waitUntil {
      model.library.loadState == .ready && model.cachedLibrary != nil && !model.isStarting
    }
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

  func setScenePhase(_ phase: ScenePhase) {
    controller.rootView.phase = phase
  }

  func expectSourceInk(_ editor: UITextView, named name: String) throws {
    window.layoutIfNeeded()
    editor.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "\(name).png", as: .png)
    let viewport = editor.convert(
      editor.bounds.inset(by: editor.adjustedContentInset).insetBy(dx: 24, dy: 4), to: window
    ).intersection(window.bounds)
    try #require(!viewport.isEmpty)
    let hit = try #require(window.hitTest(CGPoint(x: viewport.midX, y: viewport.midY), with: nil))
    #expect(hit === editor || hit.isDescendant(of: editor),
      "The visible pixels must belong to the source editor, not the preview behind it.")
    let bitmap = try #require(image.cgImage?.cropping(to: CGRect(
      x: viewport.minX * image.scale, y: viewport.minY * image.scale,
      width: viewport.width * image.scale, height: viewport.height * image.scale)))
    var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: bitmap.width, height: bitmap.height,
        bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
    }
    let ink = stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
      if Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) > 180,
        pixels[index + 3] > 200
      { count += 1 }
    }
    Attachment.record(
      """
      offset: \(editor.contentOffset), bounds: \(editor.bounds), content: \(editor.contentSize)
      insets: \(editor.adjustedContentInset), viewport: \(viewport), ink pixels: \(ink)
      first responder: \(editor.isFirstResponder), text viewport: \(String(describing: editor.textLayoutManager?.textViewportLayoutController.viewportRange))
      """, named: "\(name)-geometry.txt")
    #expect(ink > 100, "Edit must show actual source glyphs after the keyboard is dismissed.")
  }

  var isLibraryVisible: Bool {
    let bars = descendants.compactMap { $0 as? UINavigationBar }.filter {
      $0.topItem?.title == "GistPad" && isVisible($0)
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

  private struct NavigationHostRoot: View {
    let notebook: NotebookModel
    let layout: NotebookLayoutPreferences
    let routes: NotebookRouteInbox
    let columnVisibility: NavigationSplitViewVisibility
    var phase: ScenePhase = .active

    var body: some View {
      LiveNotebookWorkspace(notebook: notebook, layout: layout, routes: routes)
        .captureColumnVisibility(columnVisibility)
        .environment(\.scenePhase, phase)
    }
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

private actor NotebookCommentStoreFake: CommentConversationStore {
  private var deletedScopes: Set<CommentConversationScope> = []
  private var failsReads = false
  private var failsWrites = false
  private var archives: [CommentConversationScope: CommentDraftArchive] = [:]
  private(set) var saveCount = 0

  func fail(reads: Bool, writes: Bool) { failsReads = reads; failsWrites = writes }
  func loadDrafts(scope: CommentConversationScope) throws -> CommentDraftArchive? {
    if failsReads { throw CommentStoreFailure.unavailable }
    return archives[scope]
  }
  func saveDrafts(_ archive: CommentDraftArchive) throws {
    guard !deletedScopes.contains(archive.scope) else { throw CommentStoreFailure.unavailable }
    saveCount += 1
    if failsWrites { throw CommentStoreFailure.unavailable }
    archives[archive.scope] = archive
  }
  func removeDrafts(scope: CommentConversationScope) {
    deletedScopes.insert(scope)
    archives[scope] = nil
  }
}

private actor StubNotebookProvider: NotebookProviding, NotebookPhotoProviding, NotebookCommentProviding {
  private(set) var account: NotebookAccount
  var signInAccount: NotebookAccount
  var notes: [Gist]
  var starredNotes: [Gist]
  private var listedOwned: [Gist]?
  private var listedStarred: [Gist]?
  private var holdsLibraryRead = false
  private var heldLibraryRead: CheckedContinuation<Void, Never>?
  private var libraryReadObserver: CheckedContinuation<Void, Never>?
  var shouldFail = false
  var heldID: String?
  var heldRead: CheckedContinuation<Void, Never>?
  var readObserver: CheckedContinuation<Void, Never>?
  var cached: CachedLibrarySnapshot?
  var store: DraftStore?
  let cachesContent: Bool
  private(set) var creationCount = 0
  private(set) var inspectionCount = 0
  private(set) var localStateReads = 0
  private(set) var todayTargets: [DailyNoteTarget] = []
  private var failsToday = false
  private var holdsToday = false
  private var heldToday: CheckedContinuation<Void, Never>?
  private var todayObserver: CheckedContinuation<Void, Never>?
  private(set) var readIDs: [String] = []
  private(set) var publicationReasons: [PublishReason] = []
  private(set) var deletedIDs: [String] = []
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

  init(
    account: NotebookAccount, gists: [Gist], cachesContent: Bool = true, starred: [Gist] = []
  ) {
    self.account = account
    self.signInAccount = account
    self.notes = gists
    self.starredNotes = starred
    self.cachesContent = cachesContent
  }

  func cachedAccount() throws -> NotebookAccount? {
    cachedAccountReads += 1
    if isSigningOut { throw AccountError.signInInProgress }
    return isSignedOut ? nil : account
  }
  func photoServices(accountID: UUID) throws -> NotebookPhotoServices {
    guard accountID == account.id else { throw AccountError.accountChanged }
    let store = try draftStore()
    let storage = try ImageStorageClient(publishableKey: "sb_publishable_fixture") {
      throw URLError(.userAuthenticationRequired)
    }
    return NotebookPhotoServices(
      store: store,
      uploads: ImageUploadCoordinator(accountID: accountID, store: store, storage: storage))
  }
  func commentServices(accountID: UUID) throws -> NotebookCommentServices {
    guard accountID == account.id, !isSignedOut, !isSigningOut else {
      throw AccountError.accountChanged
    }
    return NotebookCommentServices(
      remote: GitHubCommentRemote(client: GitHubClient { throw AccountError.accountChanged }),
      userID: 1)
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
  func gists(accountID: UUID) async -> [Gist] {
    let result = listedOwned ?? notes
    if holdsLibraryRead {
      await withCheckedContinuation { continuation in
        heldLibraryRead = continuation
        libraryReadObserver?.resume()
        libraryReadObserver = nil
      }
    }
    return result
  }
  func starredGists(accountID: UUID) -> [Gist] { listedStarred ?? starredNotes }
  func setListResponses(owned: [Gist], starred: [Gist]) {
    listedOwned = owned
    listedStarred = starred
  }
  func holdLibraryRead() { holdsLibraryRead = true }
  func waitForHeldLibraryRead() async {
    if heldLibraryRead != nil { return }
    await withCheckedContinuation { libraryReadObserver = $0 }
  }
  func releaseLibraryRead() {
    holdsLibraryRead = false
    heldLibraryRead?.resume()
    heldLibraryRead = nil
  }
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
        isPublic: gist.isPublic, owner: gist.owner, truncated: gist.truncated, history: gist.history,
        commentCount: gist.commentCount)
    }
    return try await store.acknowledge(
      id: draftID, accountID: accountID, gistID: current.gistID ?? "created-\(draftID)",
      content: current.text, revision: "synthetic-revision", generation: current.generation)
  }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    if case .delete(let id) = action {
      deletedIDs.append(id)
      notes.removeAll { $0.id == id }
      starredNotes.removeAll { $0.id == id }
      return .deleted(
        gistID: id,
        drafts: try await draftStore().removeDraftsForDeletedGist(
          gistID: id, accountID: accountID))
    }
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
      inspectionCount += 1
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
      isPublic: gist.isPublic, owner: gist.owner, truncated: gist.truncated, history: gist.history,
      commentCount: gist.commentCount)
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
  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await draftStore().discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }
  func today(accountID: UUID, target: DailyNoteTarget) async throws -> TodayNote {
    todayTargets.append(target)
    if holdsToday {
      await withCheckedContinuation { continuation in
        heldToday = continuation
        todayObserver?.resume()
        todayObserver = nil
      }
    }
    if failsToday { throw URLError(.notConnectedToInternet) }
    let draft = try await draftStore().dailyGistDraft(
      accountID: accountID, githubUserID: 1, target: target)
    return TodayNote(target: target, gist: nil, draft: draft)
  }
  func failToday(_ fails: Bool) { failsToday = fails }
  func holdToday() { holdsToday = true }
  func waitForToday() async {
    if heldToday != nil { return }
    await withCheckedContinuation { todayObserver = $0 }
  }
  func releaseToday() {
    holdsToday = false
    heldToday?.resume()
    heldToday = nil
  }
  func stageExistingDraft(gistID: String, text: String) async throws -> DraftSnapshot {
    let store = try draftStore()
    let draft = try await store.openDraft(
      accountID: account.id, githubUserID: 1, gistID: gistID, filename: "README.md",
      description: "Recoverable note", content: "Base", revision: "1")
    return try await store.persist(id: draft.id, accountID: account.id, text: text, generation: 8)
  }
  func recoveryCount(draftID: UUID) async throws -> Int {
    try await draftStore().recoveries(id: draftID, accountID: account.id).count
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
  func setShowsFrontMatter(_ shown: Bool) {
    var metadata = account.preferences.metadata
    metadata["showFrontmatter"] = .bool(shown)
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
