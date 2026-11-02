import Foundation
@testable import GistPadEditor
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
  /// A pinned gist "a" tagged Ideas, like the web saves them.
  static let ideas: [PreferenceOperation] = [
    .setPinned(gistID: "a", pinned: true),
    .upsertTag(id: "ideas", name: "Ideas", color: "#EBC85A"),
    .setTag(gistID: "a", tagID: "ideas", included: true),
  ]

  // MARK: Library

  @Test func mapsOwnedStarredAndWebMetadataWithoutDuplicates() async throws {
    let fixture = try await NotebookFixture(preferences: Self.ideas) {
      $0.addGist(id: "a", description: "A note", files: ["a.md": "A"], isStarred: true)
      $0.addGist(
        id: "b", description: "A shared note", files: ["b.md": "B"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    await fixture.model.start()
    let snapshot = fixture.model.library.snapshot
    #expect(snapshot.notes.filter { !$0.isDailyNote }.count == 2)
    let note = try #require(snapshot.notes.first { $0.id == "a" })
    #expect(note.isOwned)
    #expect(note.isStarred)
    #expect(note.isPinned)
    #expect(note.isSecret)
    #expect(note.tagIDs == ["ideas"])
    #expect(snapshot.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
    #expect(snapshot.notes.first { $0.id == "b" }?.isOwned == false)
  }

  @Test func theLibraryFilterMatchesTitlesAndEveryTagAndKeepsTheOpenNoteLikeTheWeb() async throws {
    let fixture = try await NotebookFixture(
      preferences: Self.ideas, selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "A tagged needle", files: ["a.md": "A"])
      $0.addGist(id: "b", description: "An untagged needle", files: ["b.md": "B"])
      $0.addGist(id: "c", description: "Ordinary title", files: ["c.md": "A needle in the body."])
    }
    let model = fixture.model
    await model.start()
    model.library.query = "NEEDLE"
    #expect(Set(model.library.matchingNotes.map(\.id)) == ["a", "b"])
    model.library.selectedTagIDs = ["ideas"]
    #expect(model.library.matchingNotes.map(\.id) == ["a"])
    await model.open(.gist(id: "c"))
    #expect(Set(model.library.matchingNotes.map(\.id)) == ["a", "c"])
    #expect(model.library.resultGistCount == 1)
  }

  @Test func refreshDoesNotReplaceAnOpenedDocumentOrFilters() async throws {
    let fixture = try await NotebookFixture(preferences: Self.ideas) {
      $0.addGist(id: "a", description: "Original", files: ["README.md": "Original text"])
    }
    let model = fixture.model
    await model.start()
    await model.open(.gist(id: "a"))
    model.library.query = "Original"
    model.library.selectedTagIDs = ["ideas"]
    fixture.server.edit("a", description: "Changed remotely", files: ["README.md": "Remote text"])
    await model.refresh()
    #expect(model.library.snapshot.notes.first { $0.id == "a" }?.title == "Changed remotely")
    #expect(model.loadedDocument?.text == "Original text")
    #expect(model.library.query == "Original")
    #expect(model.library.selectedTagIDs == ["ideas"])
    #expect(model.library.selectedNoteID == "a")
  }

  @Test func networkFailureKeepsExistingLibraryAndDocument() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "a", description: "A note", files: ["README.md": "Text"])
    }
    let model = fixture.model
    await model.start()
    await model.open(.gist(id: "a"))
    fixture.fail()
    await model.refresh()
    #expect(model.library.snapshot.notes.filter { !$0.isDailyNote }.count == 1)
    #expect(model.loadedDocument?.gist?.id == "a")
    guard case .failed(let message) = model.library.loadState else {
      Issue.record("A failed refresh must remain visible.")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test func failedGitHubWriteRaisesAttentionUntilItsRetrySucceeds() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "a", description: "A note", files: ["README.md": "Text"])
    }
    let model = fixture.model
    await model.start()
    fixture.fail("PUT /auth/v1/user")
    _ = try? await model.perform(.preference(.setPinned(gistID: "a", pinned: true)))
    guard case .problem(let problem) = model.remoteRefreshStatus else {
      Issue.record("A failed GitHub write should raise the GitHub status control.")
      return
    }
    #expect(problem.heading == "Couldn't sync")
    #expect(problem.message == "This change wasn't saved.")
    #expect(problem.recoveryTitle == "Try Again")
    fixture.restore()
    try await model.retryWrite()
    #expect(model.writeFailure == nil)
    #expect(model.remoteRefreshStatus == .idle)
    #expect(model.library.snapshot.notes.first { $0.id == "a" }?.isPinned == true)
  }

  @Test func commentTotalsUpdateTheirLibraryRow() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(
        id: "a", description: "A conversation", files: ["README.md": "Text"],
        comments: ["One", "Two"])
    }
    let model = fixture.model
    await model.start()
    #expect(model.library.snapshot.notes.first { $0.id == "a" }?.commentCount == 2)
    model.recordCommentCount(accountID: fixture.account.id, gistID: "a", total: 3)
    #expect(model.library.snapshot.notes.first { $0.id == "a" }?.commentCount == 3)
  }

  // MARK: Opening

  @Test func anOlderOpenCannotReplaceTheNewerSelection() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "first", description: "First", files: ["README.md": "First source"])
      $0.addGist(id: "second", description: "Second", files: ["README.md": "Second source"])
    }
    let model = fixture.model
    await model.start()
    let gate = fixture.hold("GET /gists/first")
    let firstOpen = Task { await model.open(.gist(id: "first")) }
    try await gate.arrival()
    fixture.restore()
    await model.open(.gist(id: "second"))
    gate.open()
    await firstOpen.value
    #expect(model.loadedDocument?.gist?.id == "second")
    #expect(model.library.selectedNoteID == "second")
    #expect(model.opening == nil)
  }

  @Test func cachedSelectionPresentsTheTargetSynchronouslyWithoutRemoteReads() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "a", description: "First", files: ["README.md": "First source"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Second source"])
    }
    let model = fixture.model
    await model.start()
    await model.open(.gist(id: "b"))
    await model.open(.gist(id: "a"))
    let requests = fixture.server.requests
    model.select(rowID: "b")
    #expect(model.opening == nil)
    #expect(model.presentedDocument.map(model.chrome(for:))?.title == "Second")
    #expect(model.presentedDocument?.text == "Second source")
    #expect(model.activeFile?.document.gist?.id == "b")
    await Task.yield()
    #expect(fixture.server.requests == requests)
  }

  @Test func launchRestoresTheAccountScopedFileWithoutCreatingAnything() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "a", filename: "Ideas.md", draftID: nil)
    ) {
      $0.addGist(
        id: "a", description: "Last chosen", files: ["README.md": "Text", "Ideas.md": "Ideas"])
    }
    let model = fixture.model
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "a")
    #expect(model.loadedDocument?.filename == "Ideas.md")
    #expect(!model.localDrafts.contains { $0.description == GistConventions.dailyNotesDescription })
    await model.refresh()
    #expect(model.loadedDocument?.filename == "Ideas.md")
    #expect(fixture.publishes.isEmpty)
  }

  @Test func sourceUsesTheSavedFrontMatterPreferenceWithoutChangingTheDraft() async throws {
    let prefix = "---\nedit:\n  instructions: Preserve source bytes\n---\n\n"
    let source = prefix + "# Content\n\nA retained thought."
    let fixture = try await NotebookFixture(preferences: [.setBoolean(.showFrontmatter, true)]) {
      $0.addGist(id: "frontmatter", description: "Content", files: ["README.md": source])
    }
    let model = fixture.model
    await model.start()
    await model.open(.gist(id: "frontmatter"))
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    let controller = NotebookSessionController(document: document, draft: draft, notebook: model)
    let session = controller.session
    let view = session.textView
    #expect(session.showsFrontMatter)
    #expect(session.contentStart == 0)
    #expect(view.selectedRange == .init(location: 0, length: 0))
    _ = try await fixture.accounts.apply(
      [.setBoolean(.showFrontmatter, false)], accountID: fixture.account.id)
    await model.refresh()
    try await controller.refreshMetadata()
    #expect(!session.showsFrontMatter)
    #expect(session.contentStart == prefix.utf16.count)
    #expect(session.textView === view)
    #expect(session.text.utf8.elementsEqual(source.utf8))
    #expect(session.generation == draft.generation)
    #expect(view.undoManager?.canUndo != true)
  }

  // MARK: Notes on this iPhone

  @Test func newNotesAreRealDurableLocalDraftsEvenOffline() async throws {
    let fixture = try await NotebookFixture()
    let model = fixture.model
    await model.start()
    fixture.fail()
    await model.open(.new)
    let document = try #require(model.presentedDocument)
    let draft = try #require(document.draft)
    #expect(document.gist == nil)
    #expect(document.editingRequestID != nil)
    #expect(draft.gistID == nil)
    #expect(draft.state == .savedLocally)
    #expect(model.documentError == nil)
    #expect(model.library.snapshot.notes.contains { $0.id == draft.id.uuidString })
    fixture.restore()
    await model.refresh()
    await model.refresh()
    #expect(model.library.snapshot.notes.filter { $0.id == draft.id.uuidString }.count == 1)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func launchDiscardsAnAbandonedBlankDraftEvenWhenItWasRemembered() async throws {
    let fixture = try await NotebookFixture()
    let accountID = fixture.account.id
    let blank = try await fixture.store.createGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id)
    let kept = try await fixture.store.createGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id)
    let text = "Keep e\u{301}\r\n日本語 👩🏽‍💻"
    _ = try await fixture.store.persist(id: kept.id, accountID: accountID, text: text, generation: 1)
    fixture.selections.save(
      .init(gistID: nil, filename: blank.filename, draftID: blank.id), accountID: accountID)
    let model = fixture.model
    await model.start()
    let today = try #require(model.loadedDocument?.draft)
    #expect(model.isTodaySelected)
    #expect(today.isDiscardableBlank)
    #expect(Set(model.localDrafts.map(\.id)) == [kept.id, today.id])
    #expect(
      Set(model.library.snapshot.notes.map(\.id)) == [kept.id.uuidString, today.id.uuidString])
    let stored = try await fixture.store.drafts(accountID: accountID)
    #expect(stored.first { $0.id == kept.id }?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func returningToTheAppPublishesEveryLeftNoteWithUnpublishedEdits() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    _ = try await fixture.stageEdit(gistID: "a", filename: "README.md", text: "One, edited")
    _ = try await fixture.stageEdit(gistID: "b", filename: "README.md", text: "Two, edited")
    await fixture.model.start()
    await fixture.model.publishUnsyncedEdits()
    #expect(fixture.remote("a", "README.md") == "One, edited")
    #expect(fixture.remote("b", "README.md") == "Two, edited")
    #expect(fixture.publishes.sorted() == ["PATCH /gists/a", "PATCH /gists/b"])
  }

  @Test func orphanedEditedCopiesHaveStableDatesAndLocalDeletionTargets() async throws {
    let fixture = try await NotebookFixture()
    let draft = try await fixture.stageEdit(
      gistID: "gone", filename: "README.md", text: "An unpublished edit")
    let model = fixture.model
    await model.start()
    let row = try #require(model.library.snapshot.notes.first { $0.id == draft.id.uuidString })
    #expect(row.updatedAt == draft.updatedAt)
    #expect(row.isRecovery)
    let target = try #require(model.libraryDeletionTarget(for: row.id))
    #expect(target.localDraft?.id == draft.id)
    await model.refresh()
    #expect(model.library.snapshot.notes.first { $0.id == row.id }?.updatedAt == row.updatedAt)
    await model.open(.draft(id: draft.id))
    #expect(model.loadedDocument?.isRecovery == true)
    _ = try await model.perform(target.action)
    #expect(!model.localDrafts.contains { $0.id == draft.id })
    #expect(model.loadedDocument?.draft?.id != draft.id)
    #expect(model.library.selectedNoteID != row.id)
    await model.refresh()
    #expect(!model.library.snapshot.notes.contains { $0.id == row.id })
    #expect(!fixture.server.requests.contains { $0.hasPrefix("DELETE") })
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aNewlyPublishedDraftImmediatelyHasTheSameDeleteTargetAsItsNote() async throws {
    let fixture = try await NotebookFixture()
    let model = fixture.model
    await model.start()
    await model.open(.new)
    let opened = try #require(model.loadedDocument)
    let draft = try #require(opened.draft)
    #expect(model.chrome(for: opened).shareURL == nil)
    _ = try await model.persist(
      draftID: draft.id, accountID: draft.accountID, text: "A new published note", generation: 1)
    let published = try await model.publish(draftID: draft.id, accountID: draft.accountID)
    let gistID = try #require(published.gistID)
    #expect(fixture.publishes == ["POST /gists"])
    let document = try #require(model.loadedDocument)
    let shareURL = try #require(model.chrome(for: document).shareURL)
    #expect(shareURL.absoluteString.hasPrefix("https://gistpad.dev/#/share/\(gistID)/"))
    let row = try #require(model.library.snapshot.notes.first { $0.id == gistID })
    #expect(!row.isRecovery)
    #expect(!model.library.snapshot.notes.contains { $0.id == draft.id.uuidString })
    #expect(model.libraryDeletionTarget(for: row.id)?.id == gistID)
    #expect(model.libraryDeletionTarget(for: draft.id.uuidString)?.id == gistID)
    #expect(model.libraryDeletionTarget(for: row.id)?.localDraft == nil)
    #expect(model.loadedDocument?.gist?.id == gistID)
    #expect(model.library.selectedNoteID == gistID)
    #expect(!fixture.server.requests.contains("GET /gists/\(gistID)"))
  }

  @Test func libraryDeleteSeparatesRemoteGistsAndLocalCopiesFromUnpublishedAndSharedRows()
    async throws
  {
    let fixture = try await NotebookFixture {
      $0.addGist(
        id: "a", description: "An owned notebook",
        files: ["README.md": "Find this thought", "日本語.md": "Find this other thought"])
      $0.addGist(
        id: "shared", description: "A friend's notebook", files: ["README.md": "Theirs"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    let accountID = fixture.account.id
    let recovery = try await fixture.stageEdit(
      gistID: "missing", filename: "README.md", text: "Find my recovery")
    let local = try await fixture.store.createGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id)
    _ = try await fixture.store.persist(
      id: local.id, accountID: accountID, text: "Find my local draft", generation: 1)
    let model = fixture.model
    await model.start()
    let target = try #require(model.libraryDeletionTarget(for: "a"))
    #expect(target.id == "a")
    #expect(target.title == "An owned notebook")
    #expect(target.accountID == accountID)
    #expect(model.libraryDeletionTarget(for: recovery.id.uuidString)?.localDraft?.id == recovery.id)
    #expect(model.libraryDeletionTarget(for: local.id.uuidString)?.localDraft?.id == local.id)
    for id in ["missing", "unknown", "shared"] {
      #expect(model.libraryDeletionTarget(for: id) == nil)
    }
    #expect(model.localDrafts.first { $0.id == local.id }?.text == "Find my local draft")
    #expect(model.localDrafts.first { $0.id == recovery.id }?.text == "Find my recovery")
    #expect(!fixture.server.requests.contains { $0.hasPrefix("DELETE") })
  }

  @Test func deletingALibraryGistRemovesItsRowAndDraftsAndQuietlyOpensToday() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "a", description: "A published note", files: ["README.md": "Text"])
    }
    let model = fixture.model
    await model.start()
    await model.open(.gist(id: "a"))
    let draft = try #require(model.loadedDocument?.draft)
    _ = try await model.persist(
      draftID: draft.id, accountID: draft.accountID, text: "An accepted edit", generation: 1)
    _ = try await model.publish(draftID: draft.id, accountID: draft.accountID)
    let target = try #require(model.libraryDeletionTarget(for: "a"))
    _ = try await model.perform(.delete(gistID: target.id))
    #expect(fixture.server.requests.filter { $0.hasPrefix("DELETE") } == ["DELETE /gists/a"])
    #expect(fixture.server.gists.isEmpty)
    #expect(model.isTodaySelected)
    #expect(model.loadedDocument?.editingRequestID == nil)
    #expect(model.library.selectedNoteID == model.loadedDocument?.rowID)
    #expect(model.libraryDeletionTarget(for: "a") == nil)
    #expect(model.library.snapshot.notes.allSatisfy { $0.isDailyNote })
    #expect(try await fixture.store.drafts(accountID: fixture.account.id).allSatisfy {
      $0.gistID != "a"
    })
    let relaunched = fixture.relaunch()
    await relaunched.start()
    #expect(relaunched.library.snapshot.notes.allSatisfy { $0.isDailyNote })
    #expect(relaunched.isTodaySelected)
  }

  // MARK: Account

  @Test func signOutRetainsExactDraftsAndRestoresTheSameAccount() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Kept on this iPhone", files: ["README.md": "Base"])
    }
    let text = "Private e\u{301}\r\n日本語 👩🏽‍💻"
    let draft = try await fixture.stageEdit(gistID: "a", filename: "README.md", text: text)
    let model = fixture.model
    await model.start()
    #expect(model.loadedDocument?.draft?.id == draft.id)
    _ = try await model.perform(.signOut)
    #expect(model.account == nil)
    #expect(model.loadedDocument == nil)
    #expect(model.cachedLibrary == nil)
    #expect(model.library.snapshot.notes.isEmpty)
    #expect(model.library.loadState == .signedOut)
    let kept = try await fixture.store.drafts(accountID: fixture.account.id)
    #expect(kept.first { $0.id == draft.id }?.text.utf8.elementsEqual(text.utf8) == true)
    await model.signIn()
    #expect(model.account?.id == fixture.account.id)
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(model.loadedDocument?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func anotherAccountSigningInWaitsAndKeepsTheOriginalDrafts() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Original account", files: ["README.md": "Base"])
    }
    let text = "日本語 e\u{301}\r\n**Private draft**"
    let local = try await fixture.stageEdit(gistID: "a", filename: "README.md", text: text)
    let model = fixture.model
    await model.start()
    let other = UUID()
    try fixture.signInNext(as: other, login: FixtureServer.someoneElse.login)
    await model.signIn()
    #expect(model.account?.id == fixture.account.id)
    #expect(model.pendingAccount?.id == other)
    #expect(model.loadedDocument?.accountID == fixture.account.id)
    guard case .reconnectRequired = model.library.loadState else {
      Issue.record("An account switch must not silently adopt another account.")
      return
    }
    model.keepCurrentNotebook()
    #expect(model.account?.id == fixture.account.id)
    #expect(model.pendingAccount == nil)
    let kept = try await fixture.store.drafts(accountID: fixture.account.id)
    #expect(kept.first { $0.id == local.id }?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(try await fixture.store.drafts(accountID: other).isEmpty)
  }

  // MARK: Daily notes

  @Test func coldStartEnsuresTodayQuietlyWithoutPublishingAnUntouchedTemplate() async throws {
    let fixture = try await NotebookFixture()
    let model = fixture.model
    await model.start()
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    #expect(document.filename == DailyNoteTarget().filename)
    #expect(document.editingRequestID == nil)
    #expect(model.isTodaySelected)
    #expect(draft.isDiscardableBlank)
    let controller = NotebookSessionController(
      document: document, draft: draft, notebook: model, autosaveDelay: .milliseconds(1))
    #expect(!controller.hasUnpublishedChanges)
    #expect(controller.autosave(foreground: true) == nil)
    await controller.publish(reason: .background)
    #expect(fixture.publishes.isEmpty)
    await model.open(.today())
    #expect(model.loadedDocument?.draft?.id == draft.id)
    #expect(model.loadedDocument?.editingRequestID != nil)
    controller.adoptPresentation(try #require(model.loadedDocument))
    controller.requestCreationFocus()
    #expect(controller.mode == .source)
    controller.mode = .reading
    controller.requestCreationFocus()
    #expect(controller.mode == .reading, "A render does not repeat the same editing request.")
    await model.open(.today())
    controller.adoptPresentation(try #require(model.loadedDocument))
    controller.requestCreationFocus()
    #expect(controller.mode == .source, "A fresh Today action focuses the retained editor again.")
  }

  @Test func twoTodayTapsMakeOneDailyNote() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
    }
    let model = fixture.model
    await model.start()
    let first = Task { await model.open(.today()) }
    let second = Task { await model.open(.today()) }
    await first.value
    await second.value
    let today = try #require(model.loadedDocument?.draft)
    #expect(today.filename == DailyNoteTarget().filename)
    _ = try await model.persist(
      draftID: today.id, accountID: today.accountID, text: "- [ ] One task", generation: 1)
    _ = try await model.publish(draftID: today.id, accountID: today.accountID)
    await model.open(.gist(id: "a"))
    await model.open(.today())
    #expect(model.loadedDocument?.draft?.id == today.id)
    let dailies = try await fixture.store.drafts(accountID: fixture.account.id).filter {
      $0.description == GistConventions.dailyNotesDescription
    }
    #expect(dailies.map(\.id) == [today.id])
    #expect(fixture.publishes == ["POST /gists"])
    #expect(fixture.server.gists.filter(\.isDailyNote).map { Array($0.files.keys) }
      == [[today.filename]])
  }

  @Test func anExplicitTodayActionPinsTheRequestedDayWithoutAnInterstitial() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Last chosen", files: ["README.md": "Text"])
    }
    let model = fixture.model
    await model.start()
    #expect(model.loadedDocument?.gist?.id == "a")
    let target = DailyNoteTarget(
      date: Date(timeIntervalSince1970: 1_790_208_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    await model.open(.today(target))
    #expect(model.loadedDocument?.draft?.filename == target.filename)
    #expect(model.loadedDocument?.editingRequestID != nil)
  }

  @Test func aDailyRowShowsItsDayAndTaskProgress() async throws {
    let filename = GistConventions.todayFilename()
    let fixture = try await NotebookFixture {
      $0.addGist(
        id: "daily", description: GistConventions.dailyNotesDescription,
        files: [filename: "- [x] One\n- [ ] Two\nA third line stays out of the excerpt."])
    }
    let model = fixture.model
    await model.start()
    let row = try #require(model.library.unfilteredNotes(in: .dailyNotes).first)
    #expect(row.id == "daily/\(filename)")
    #expect(row.dailyDate == DailyNotesIndex.parseDateFilename(filename))
    #expect(model.library.dailyNoteCount == 1)
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(model.library.today.progress == .init(completed: 1, total: 2))
    await model.openRow(id: row.id)
    #expect(model.loadedDocument?.filename == filename)
    #expect(model.library.selectedNoteID == row.id)
  }

  @Test func unfilteredDailyRowsResolveTheirGistAndRefreshOverdueOnCalendarChanges() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(
        id: "daily", description: GistConventions.dailyNotesDescription,
        files: ["2026-01-02.md": "- [ ] Carried over"])
    }
    let model = fixture.model
    await model.start()
    let rowID = "daily/2026-01-02.md"
    // GitHub lists gists without their text, so a day's tasks are known once it's been opened.
    await model.openRow(id: rowID)
    #expect(model.gistID(forRow: rowID) == "daily")
    #expect(model.gistID(forRow: "daily/2026-01-03.md") == nil)
    let index = try #require(model.library.snapshot.notes.firstIndex { $0.id == rowID })
    #expect(model.library.snapshot.notes[index].isOverdue)
    // A row projected before midnight is stale until the calendar changes.
    model.library.snapshot.notes[index].isOverdue = false
    model.updateCalendar()
    #expect(model.library.snapshot.notes[index].isOverdue)
  }

  @Test func dailyRowsOpenAndDeleteTheirExactFile() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(
        id: "daily", description: GistConventions.dailyNotesDescription,
        files: ["2026-10-23.md": "The alpha day", "2026-10-24.md": "The beta day"])
    }
    let model = fixture.model
    await model.start()
    await model.openRow(id: "daily/2026-10-24.md")
    #expect(model.loadedDocument?.filename == "2026-10-24.md")
    #expect(model.loadedDocument?.text == "The beta day")
    #expect(model.library.selectedNoteID == "daily/2026-10-24.md")
    await model.openRow(id: "daily/2026-10-23.md")
    #expect(model.loadedDocument?.text == "The alpha day")
    #expect(model.library.selectedNoteID == "daily/2026-10-23.md")
    await model.open(.gist(id: "daily", filename: "2026-10-24.md"))
    #expect(model.library.selectedNoteID == "daily/2026-10-24.md")
    #expect(model.loadedDocument?.rowID == "daily/2026-10-24.md")
    let deletion = try #require(model.libraryDeletionTarget(for: "daily/2026-10-24.md"))
    #expect(deletion.id == "daily")
    #expect(deletion.title == GistConventions.fileDisplayName("2026-10-24.md"))
    if case .deleteFile(let gistID, let filename) = deletion.action {
      #expect(gistID == "daily")
      #expect(filename == "2026-10-24.md")
    } else {
      Issue.record("A Daily row deletes only its own file.")
    }
  }

  @Test func persistingAndPublishingANewDailyFileKeepItsExactRowAndTaskProgress() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "daily", filename: "2026-10-23.md", draftID: nil)
    ) {
      $0.addGist(
        id: "daily", description: GistConventions.dailyNotesDescription,
        files: ["2026-10-23.md": "An earlier day"])
    }
    let draft = try await fixture.stageEdit(
      gistID: "daily", filename: "2026-10-24.md", text: "- [ ] A retained task")
    let model = fixture.model
    await model.start()
    await model.openRow(id: "daily/2026-10-24.md")
    let documentID = try #require(model.loadedDocument?.id)
    let text = "- [x] A retained task\n- [ ] A new task"
    _ = try await model.persist(
      draftID: draft.id, accountID: draft.accountID, text: text, generation: draft.generation + 1)
    let row = try #require(model.library.snapshot.notes.first { $0.id == "daily/2026-10-24.md" })
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(row.isOverdue)
    #expect(model.library.dailyNoteCount == 2)
    _ = try await model.publish(draftID: draft.id, accountID: draft.accountID)
    #expect(fixture.remote("daily", "2026-10-24.md") == text)
    #expect(fixture.publishes == ["PATCH /gists/daily"])
    #expect(model.loadedDocument?.id == documentID)
    #expect(model.library.selectedNoteID == row.id)
    #expect(model.library.dailyNoteCount == 2)
    #expect(model.library.snapshot.notes.filter { $0.id == row.id }.count == 1)
    #expect(!model.library.snapshot.notes.contains { $0.id == draft.id.uuidString })
  }

  @Test func deletingADailyNoteRemovesOnlyItsFileOrTheGistWithItsLastFile() async throws {
    let fixture = try await NotebookFixture(
      selection: .init(gistID: "daily", filename: "2026-10-23.md", draftID: nil)
    ) {
      $0.addGist(
        id: "daily", description: GistConventions.dailyNotesDescription,
        files: ["2026-10-23.md": "The alpha day", "2026-10-24.md": "The beta day"])
    }
    let model = fixture.model
    await model.start()
    #expect(model.library.dailyNoteCount == 2)
    let beta = try #require(model.libraryDeletionTarget(for: "daily/2026-10-24.md"))
    _ = try await model.perform(beta.action)
    #expect(model.library.dailyNoteCount == 1)
    #expect(model.library.snapshot.notes.map(\.id) == ["daily/2026-10-23.md"])
    #expect(fixture.remote("daily", "2026-10-24.md") == nil)
    #expect(fixture.remote("daily", "2026-10-23.md") == "The alpha day")
    let alpha = try #require(model.libraryDeletionTarget(for: "daily/2026-10-23.md"))
    _ = try await model.perform(alpha.action)
    #expect(fixture.server.gists.isEmpty)
    #expect(!model.library.snapshot.notes.contains { $0.gistID == "daily" })
  }
}

@Suite(.serialized)
@MainActor
struct NotebookNavigationHostTests {
  @Test func reopeningPreviewThenEditKeepsTheSourceOnScreen() async throws {
    let source = """
      ---
      edit:
        instructions: >-
          Preserve the reading list's existing sections and entries.
      ---

      # A visible reading list

      """
      + (1...300).map { "\($0). A retained reading entry \($0)\n" }.joined()
      + "\nAn exact final source line."
    let other = "# Another note\n\nA different retained source."
    let fixture = try await NotebookFixture(autosave: false) {
      $0.addGist(
        id: "reading", description: "Reading list",
        files: ["README.md": source, "Calendar.md": "# A second file"])
      $0.addGist(id: "other", description: "Another note", files: ["README.md": other])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact, mode: .reading)
    defer { await host.close() }
    var retained: UITextView?
    for id in ["reading", "other", "reading"] {
      let text = id == "reading" ? source : other
      host.model.select(rowID: id)
      try await host.waitUntil {
        host.model.presentedDocument?.gist?.id == id && host.editor(text: text) != nil
          && host.picker != nil
      }
      let editor = try #require(host.editor(text: text))
      if id == "reading" {
        if let retained { #expect(editor === retained) } else { retained = editor }
      }
      if id == "other" {
        // Unfolding the Duo gives Split. Folding it again keeps the same source.
        let compactWidth = host.window.frame.width
        host.window.traitOverrides.horizontalSizeClass = .regular
        host.window.frame.size.width = 1180
        try await host.waitUntil { host.picker?.numberOfSegments == 3 }
        host.layout.select(.split)
        try await host.waitUntil { host.isVisible(editor) }
        host.window.traitOverrides.horizontalSizeClass = .compact
        host.window.frame.size.width = compactWidth
        try await host.waitUntil { host.picker?.numberOfSegments == 2 }
        host.layout.select(.reading)
      }
      for showsPreview in [true, false] {
        let picker = try #require(host.picker)
        picker.selectedSegmentIndex = showsPreview ? picker.numberOfSegments - 1 : 0
        picker.sendActions(for: .valueChanged)
        if showsPreview {
          let preview = try #require(host.descendants.compactMap { $0 as? WKWebView }.first)
          var rendered = false
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          while !rendered, ContinuousClock.now < deadline {
            rendered = try await preview.callAsyncJavaScript(
              "return document.body.innerText.includes('retained');",
              arguments: [:], in: nil, contentWorld: .page) as? Bool == true
            if !rendered { try await Task.sleep(for: .milliseconds(20)) }
          }
          #expect(rendered)
        } else {
          try await host.waitForKeyboard(visible: true)
          let position = try #require(editor.selectedTextRange?.end)
          let caret = editor.convert(editor.caretRect(for: position), to: host.window)
          let bar = try #require(host.descendants.compactMap { $0 as? UINavigationBar }.last)
          let top = bar.convert(bar.bounds, to: host.window).maxY
          #expect(editor.isFirstResponder)
          #expect(host.isVisible(editor))
          #expect(editor.text.utf8.elementsEqual(text.utf8))
          #expect(
            editor.selectedRange
              == NSRange(location: MarkdownFrontMatter.contentStart(in: text), length: 0))
          #expect(caret.minY >= top - 1 && caret.minY < top + 40)
          editor.resignFirstResponder()
          try await host.waitForKeyboard(visible: false)
          #expect(host.isVisible(editor))
        }
      }
      host.returnToLibrary()
      try await host.waitUntil { host.isLibraryVisible }
    }
  }

  @Test func leavingANewBlankNoteDiscardsItsDraftWithoutPublishing() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "kept", description: "Kept", files: ["README.md": "A real note"])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
    defer { await host.close() }
    // Creating is local, so it works offline.
    fixture.fail()
    await host.model.open(.new)
    let first = try #require(host.model.presentedDocument?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    #expect(host.editor(text: "")?.selectedRange == NSRange(location: 0, length: 0))
    try await host.waitForKeyboard(visible: true)
    fixture.restore()
    host.routes.submit(.note(gistID: "kept", filename: nil))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "A real note") != nil
        && !host.model.localDrafts.contains { $0.id == first.id }
    }
    #expect(host.model.library.selectedNoteID == "kept")

    await host.model.open(.new)
    let second = try #require(host.model.presentedDocument?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    host.returnToLibrary()
    try await host.waitUntil {
      host.isLibraryVisible && !host.model.localDrafts.contains { $0.id == second.id }
        && host.model.isTodaySelected
    }
    #expect(host.model.loadedDocument?.editingRequestID == nil)
    let stored = try await fixture.store.drafts(accountID: fixture.account.id).map(\.id)
    #expect(!stored.contains(first.id) && !stored.contains(second.id))
    #expect(fixture.publishes.isEmpty)
  }

  @Test(arguments: [true, false])
  func returningToLibraryPublishesTheOutgoingNoteAndKeepsItsEditor(autosave: Bool) async throws {
    let fixture = try await NotebookFixture(autosave: autosave) {
      $0.addGist(id: "a", description: "Current", files: ["README.md": "Current source"])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
    defer { await host.close() }
    await host.model.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 0, length: 0)
    editor.insertText("Local ")
    try await host.waitUntil {
      host.model.localDrafts.first { $0.gistID == "a" }?.generation == 1
    }
    host.returnToLibrary()
    // Well before autosave's quiet timer.
    try await host.waitUntil(timeout: .seconds(1)) {
      fixture.remote("a", "README.md") == "Local Current source"
    }
    try await host.waitUntil { host.isLibraryVisible }
    #expect(fixture.publishes == ["PATCH /gists/a"])
    #expect(host.model.library.selectedNoteID == nil)
    #expect(!editor.isFirstResponder)
    let selection = editor.selectedRange
    host.routes.submit(.note(gistID: "a", filename: nil))
    try await host.waitUntil {
      host.routes.pending == nil && host.editor(text: "Local Current source") === editor
        && !host.isLibraryVisible
    }
    #expect(editor.selectedRange == selection)
  }

  @Test func switchingNotesMidCompositionKeepsAndPublishesTheComposedText() async throws {
    let fixture = try await NotebookFixture(autosave: false) {
      $0.addGist(id: "a", description: "First note", files: ["README.md": "First note source"])
      $0.addGist(id: "b", description: "Second note", files: ["README.md": "Second note source"])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    host.model.select(rowID: "a")
    try await host.waitUntil { host.editor(text: "First note source") != nil }
    let first = try #require(host.editor(text: "First note source"))
    try #require(first.becomeFirstResponder())
    first.selectedRange = NSRange(location: 0, length: 0)
    first.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
    try #require(first.markedTextRange != nil)
    host.model.select(rowID: "b")
    try await host.waitUntil { host.editor(text: "Second note source") != nil }
    #expect(first.markedTextRange == nil)
    #expect(first.text == "にほんごFirst note source")
    try await host.waitUntil { fixture.remote("a", "README.md") == "にほんごFirst note source" }
    #expect(fixture.publishes == ["PATCH /gists/a"])
  }

  @Test func startingTodayFocusesTheCaretAfterItsDurableInitialContent() async throws {
    let fixture = try await NotebookFixture()
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.model.open(.today())
    let draft = try #require(host.model.presentedDocument?.draft)
    #expect(!draft.text.isEmpty)
    try await host.waitUntil { host.editor(text: draft.text)?.isFirstResponder == true }
    let editor = try #require(host.editor(text: draft.text))
    #expect(editor.selectedRange == NSRange(location: draft.text.utf16.count, length: 0))
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aColdRouteWaitsForRestorationAndOpensTheExactFile() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(
        id: "b", description: "Routed note",
        files: ["README.md": "Text", "Ideas.md": "Routed file source"])
    }
    let routes = NotebookRouteInbox()
    routes.submit(.note(gistID: "b", filename: "Ideas.md"))
    let host = try await NavigationHost(fixture: fixture, routes: routes)
    defer { await host.close() }
    try await host.waitUntil {
      routes.pending == nil && host.editor(text: "Routed file source") != nil
    }
    #expect(host.model.loadedDocument?.filename == "Ideas.md")
    #expect(host.model.loadedDocument?.gist?.id == "b")
  }

  @Test func aFailedOpenShowsItsOwnTitleAndRetryInsteadOfThePreviousEditor() async throws {
    let fixture = try await NotebookFixture {
      $0.addGist(id: "a", description: "Previous", files: ["README.md": "Previous source"])
      $0.addGist(
        id: "b", description: "Requested",
        files: ["README.md": "Text", "Other.md": "Retried source"])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.model.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "Previous source") != nil }
    fixture.fail("GET /gists/b")
    await host.model.open(.gist(id: "b", filename: "Other.md", rowID: "result-b"))
    try await host.waitUntil {
      host.descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }.contains("Requested")
    }
    #expect(host.editor(text: "Previous source") == nil)
    fixture.restore()
    try await host.model.open(#require(host.model.opening).request)
    try await host.waitUntil { host.editor(text: "Retried source") != nil }
    #expect(notebookAccessibilityElement("note-open-retry", in: host.window) == nil)
    #expect(host.model.loadedDocument?.gist?.id == "b")
    #expect(host.model.library.selectedNoteID == "b")
    #expect(host.model.loadedDocument?.filename == "Other.md")
  }

  @Test func sourceIntelligenceOpensTheLiveSheetForTheRetainedEditor() async throws {
    let fixture = try await NotebookFixture(autosave: false) {
      $0.addGist(
        id: "a", description: "A retained thought", files: ["README.md": "A little room to think."])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.model.open(.gist(id: "a"))
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
    let root = try #require(host.window.rootViewController)
    try await host.waitUntil { intelligencePrompt(presentedOver: root) != nil }
    #expect(!editor.isFirstResponder)
    #expect(editor.selectedRange == selection)
    #expect(host.editor(text: "A little room to think.") === editor)
    #expect(fixture.publishes.isEmpty)
  }
}

/// The app's workspace in a real window, around a fixture notebook.
@MainActor
private struct NavigationHost {
  let model: NotebookModel
  let window: UIWindow
  let routes: NotebookRouteInbox
  let layout: NotebookLayoutPreferences
  private let suite: String
  private let previousWindow: UIWindow?

  init(
    fixture: NotebookFixture, routes: NotebookRouteInbox = NotebookRouteInbox(),
    sizeClass: UIUserInterfaceSizeClass? = nil, mode: NoteMode = .source
  ) async throws {
    model = fixture.model
    self.routes = routes
    suite = "NotebookNavigationHost-\(UUID())"
    layout = NotebookLayoutPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    layout.select(mode)
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
      rootView: LiveNotebookWorkspace(notebook: model, layout: layout, routes: routes))
    window.makeKeyAndVisible()
    let model = model
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

  /// The note's Edit, Preview (and Split, when wide) control.
  var picker: UISegmentedControl? {
    descendants.compactMap { $0 as? UISegmentedControl }.last
  }

  /// Pops the pushed note the way the system back button does on iPhone.
  func returnToLibrary() {
    descendants.lazy.compactMap { $0.next as? UINavigationController }
      .first { $0.viewControllers.count > 1 }?
      .popViewController(animated: false)
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

  func waitForKeyboard(visible: Bool, resigning: Bool = false) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var previous: CGRect?
    var stableSince = ContinuousClock.now
    while ContinuousClock.now < deadline {
      if resigning { window.endEditing(true) }
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
    Issue.record(
      "The real keyboard did not settle \(visible ? "on screen" : "off screen"): \(keyboardFrame).")
    throw HostError.presentationTimedOut
  }

  func waitUntil(
    timeout: Duration = .seconds(5), _ predicate: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        Attachment.record(
          """
          load: \(model.library.loadState)
          loaded: \(String(describing: model.loadedDocument?.id))
          presented: \(String(describing: model.presentedDocument?.id))
          opening: \(String(describing: model.opening))
          error: \(String(describing: model.documentError))
          route: \(String(describing: routes.pending))
          library visible: \(isLibraryVisible)
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
    window.rootViewController?.dismiss(animated: false)
    // A closing sheet hands focus back to the note it came from, a beat after it's gone.
    do {
      try await waitForKeyboard(visible: false, resigning: true)
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
