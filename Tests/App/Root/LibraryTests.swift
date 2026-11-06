import Foundation
@testable import Editor
import Interface
import Platform
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad
@testable import Sync

@MainActor
struct LibraryTests {
  /// A pinned gist "a" tagged Ideas, like the web saves them.
  static let ideas: [Preferences.Change] = [
    .setPinned(gistID: "a", pinned: true),
    .upsertTag(id: "ideas", name: "Ideas", color: "#EBC85A"),
    .setTag(gistID: "a", tagID: "ideas", included: true),
  ]

  // MARK: Library

  @Test func mapsOwnedStarredAndWebMetadataWithoutDuplicates() async throws {
    let fixture = try await LibraryFixture(preferences: Self.ideas) {
      $0.addGist(id: "a", description: "A note", files: ["a.md": "A"], isStarred: true)
      $0.addGist(
        id: "b", description: "A shared note", files: ["b.md": "B"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    await fixture.library.start()
    let state = fixture.library.state
    #expect(state.gists.filter { !$0.isDailyNote }.count == 2)
    let note = try #require(state.gists.first { $0.id == "a" })
    #expect(note.isOwned)
    #expect(note.isStarred)
    #expect(note.isPinned)
    #expect(note.isSecret)
    #expect(note.tagIDs == ["ideas"])
    #expect(state.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
    #expect(state.gists.first { $0.id == "b" }?.isOwned == false)
  }

  @Test func yourGistsStayEditableAfterAGitHubLoginRename() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "Mine", files: ["README.md": "Mine"])
      // The account still carries the login from before the rename.
      $0.mergeMetadata(["user_name": "octocat-before-rename"])
    }
    let library = fixture.library
    await library.start()
    await library.open(.gist(id: "a"))
    #expect(fixture.account.login == "octocat-before-rename")
    #expect(library.loadedFile.map(library.details(for:))?.access == .editable)
  }

  @Test func refreshDoesNotReplaceAnOpenFileOrFilters() async throws {
    let fixture = try await LibraryFixture(preferences: Self.ideas) {
      $0.addGist(id: "a", description: "Original", files: ["README.md": "Original text"])
    }
    let library = fixture.library
    await library.start()
    await library.open(.gist(id: "a"))
    library.state.query = "Original"
    library.state.selectedTagIDs = ["ideas"]
    fixture.server.edit("a", description: "Changed remotely", files: ["README.md": "Remote text"])
    await library.refresh()
    #expect(library.state.gists.first { $0.id == "a" }?.title == "Changed remotely")
    #expect(library.loadedFile?.text == "Original text")
    #expect(library.state.query == "Original")
    #expect(library.state.selectedTagIDs == ["ideas"])
    #expect(library.state.selectedID == "a")
  }

  /// A launch link can open a gist before GitHub's list arrives. The gist's row then replaces the
  /// draft's, and the open gist stays selected under it.
  @Test func aGistOpenedBeforeTheListArrivesStaysSelected() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "Opened early", files: ["README.md": "Text"])
    }
    let library = fixture.library
    let list = fixture.hold("GET /gists/starred")
    let start = Task { await library.start() }
    try await list.arrival()
    await library.open(.gist(id: "a"))
    #expect(library.state.selectedID == library.loadedFile?.draft?.id.uuidString)
    list.open()
    await start.value
    #expect(library.state.selectedID == "a")
    #expect(library.loadedFile?.rowID == "a")
  }

  /// A refresh cut off by leaving the app can come back as a timeout. Returning retries it, and
  /// shows checking rather than the problem until the retry settles.
  @Test func returningToTheAppRetriesAFailedRefresh() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "A note", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    fixture.fail("GET /gists")
    await library.refresh()
    guard case .problem = library.remoteRefreshStatus else {
      Issue.record("The failed refresh should show its problem.")
      return
    }
    let retry = fixture.hold("GET /gists/starred")
    let returning = Task { await library.refreshOnReturn() }
    try await retry.arrival()
    guard case .checking = library.remoteRefreshStatus else {
      Issue.record("The retry should show as checking.")
      return
    }
    retry.open()
    await returning.value
    #expect(library.remoteRefreshStatus == .idle)
    #expect(library.state.loadState == .ready)
  }

  /// A refresh that only timed out or lost its connection keeps the list without a problem, and
  /// returning to the app tries again.
  @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
  func aDroppedRefreshShowsNothing(_ code: URLError.Code) async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "A note", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    fixture.fail("GET /gists", with: code)
    await library.refresh()
    #expect(library.remoteRefreshStatus == .idle)
    #expect(library.state.loadState == .ready)
    #expect(library.state.gists.contains { $0.id == "a" })
    fixture.restore()
    fixture.server.edit("a", description: "Changed on the web")
    await library.refreshOnReturn()
    #expect(library.state.gists.first { $0.id == "a" }?.title == "Changed on the web")
  }

  @Test func networkFailureKeepsExistingLibraryAndFile() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "A note", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    await library.open(.gist(id: "a"))
    fixture.fail()
    await library.refresh()
    #expect(library.state.gists.filter { !$0.isDailyNote }.count == 1)
    #expect(library.loadedFile?.gist?.id == "a")
    guard case .failed(let message) = library.state.loadState else {
      Issue.record("A failed refresh must remain visible.")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test func failedGitHubWriteRaisesAttentionUntilItsRetrySucceeds() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "A note", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    fixture.fail("PUT /auth/v1/user")
    _ = try? await library.perform(.preferences([.setPinned(gistID: "a", pinned: true)]))
    guard case .problem(let problem) = library.remoteRefreshStatus else {
      Issue.record("A failed GitHub write should raise the GitHub status control.")
      return
    }
    #expect(problem.heading == "Couldn't sync")
    #expect(problem.message == "This change wasn't saved.")
    #expect(problem.recoveryTitle == "Try Again")
    fixture.restore()
    try await library.retryPublish()
    #expect(library.unsentChange == nil)
    #expect(library.remoteRefreshStatus == .idle)
    #expect(library.state.gists.first { $0.id == "a" }?.isPinned == true)
  }

  @Test func commentTotalsUpdateTheirLibraryRow() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "a", description: "A conversation", files: ["README.md": "Text"],
        comments: ["One", "Two"])
    }
    let library = fixture.library
    await library.start()
    #expect(library.state.gists.first { $0.id == "a" }?.commentCount == 2)
    library.recordCommentCount(accountID: fixture.account.id, gistID: "a", total: 3)
    #expect(library.state.gists.first { $0.id == "a" }?.commentCount == 3)
  }

  @Test func aRowCountsTheFilesItsGistShowsFromTwo() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "a", description: "Several", files: ["README.md": "A", "Ideas.md": "B", "diagram.png": "PNG"])
      $0.addGist(id: "b", description: "One", files: ["README.md": "A"])
    }
    let library = fixture.library
    await library.start()
    let row = { id in library.state.gists.first { $0.id == id } }
    #expect(row("a")?.visibleFileCount == 2)
    #expect(row("b")?.visibleFileCount == nil)
    _ = try await library.perform(.addFile(gistID: "b", filename: "More.md"))
    #expect(row("b")?.visibleFileCount == 2)
  }

  // MARK: Opening

  @Test func anOlderOpenCannotReplaceTheNewerSelection() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "first", description: "First", files: ["README.md": "First source"])
      $0.addGist(id: "second", description: "Second", files: ["README.md": "Second source"])
    }
    let library = fixture.library
    await library.start()
    let gate = fixture.hold("GET /gists/first")
    let firstOpen = Task { await library.open(.gist(id: "first")) }
    try await gate.arrival()
    fixture.restore()
    await library.open(.gist(id: "second"))
    gate.open()
    await firstOpen.value
    #expect(library.loadedFile?.gist?.id == "second")
    #expect(library.state.selectedID == "second")
    #expect(library.opening == nil)
  }

  @Test func cachedSelectionPresentsTheTargetSynchronouslyWithoutRemoteReads() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "First", files: ["README.md": "First source"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Second source"])
    }
    let library = fixture.library
    await library.start()
    await library.open(.gist(id: "b"))
    await library.open(.gist(id: "a"))
    let requests = fixture.server.requests
    library.select(rowID: "b")
    #expect(library.opening == nil)
    #expect(library.visibleFile.map(library.details(for:))?.title == "Second")
    #expect(library.visibleFile?.text == "Second source")
    #expect(library.activeSession?.file.gist?.id == "b")
    await Task.yield()
    #expect(fixture.server.requests == requests)
  }

  @Test func launchRestoresTheAccountScopedFileWithoutCreatingAnything() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "Ideas.md", draftID: nil)
    ) {
      $0.addGist(
        id: "a", description: "Last chosen", files: ["README.md": "Text", "Ideas.md": "Ideas"])
    }
    let library = fixture.library
    await library.start()
    #expect(library.loadedFile?.gist?.id == "a")
    #expect(library.loadedFile?.filename == "Ideas.md")
    #expect(!library.localDrafts.contains { $0.description == DailyNote.gistDescription })
    await library.refresh()
    #expect(library.loadedFile?.filename == "Ideas.md")
    #expect(fixture.publishes.isEmpty)
  }

  @Test func sourceUsesTheSavedFrontMatterPreferenceWithoutChangingTheDraft() async throws {
    let prefix = "---\nedit:\n  instructions: Preserve source bytes\n---\n\n"
    let source = prefix + "# Content\n\nA retained thought."
    let fixture = try await LibraryFixture(preferences: [.setBoolean(.showFrontmatter, true)]) {
      $0.addGist(id: "frontmatter", description: "Content", files: ["README.md": source])
    }
    let library = fixture.library
    await library.start()
    await library.open(.gist(id: "frontmatter"))
    let file = try #require(library.loadedFile)
    let draft = try #require(file.draft)
    let session = FileSession(file: file, draft: draft, library: library)
    let editor = session.editor
    let view = editor.textView
    #expect(editor.showsFrontMatter)
    #expect(editor.contentStart == 0)
    #expect(view.selectedRange == .init(location: 0, length: 0))
    _ = try await fixture.accounts.update(
      [.setBoolean(.showFrontmatter, false)], accountID: fixture.account.id)
    await library.refresh()
    try await session.refreshMetadata()
    #expect(!editor.showsFrontMatter)
    #expect(editor.contentStart == prefix.utf16.count)
    #expect(editor.textView === view)
    #expect(editor.text.utf8.elementsEqual(source.utf8))
    #expect(editor.generation == draft.generation)
    #expect(view.undoManager?.canUndo != true)
  }

  // MARK: Files on this iPhone

  @Test func newNotesAreRealDurableLocalDraftsEvenOffline() async throws {
    let fixture = try await LibraryFixture()
    let library = fixture.library
    await library.start()
    fixture.fail()
    await library.open(.new)
    let file = try #require(library.visibleFile)
    let draft = try #require(file.draft)
    #expect(file.gist == nil)
    #expect(file.editingRequestID != nil)
    #expect(draft.gistID == nil)
    #expect(draft.state == .savedLocally)
    #expect(library.openError == nil)
    #expect(library.state.gists.contains { $0.id == draft.id.uuidString })
    fixture.restore()
    await library.refresh()
    await library.refresh()
    #expect(library.state.gists.filter { $0.id == draft.id.uuidString }.count == 1)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func launchDiscardsAnAbandonedBlankDraftEvenWhenItWasRemembered() async throws {
    let fixture = try await LibraryFixture()
    let accountID = fixture.account.id
    let blank = try await fixture.store.newGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id)
    let kept = try await fixture.store.newGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id)
    let text = "Keep e\u{301}\r\n日本語 👩🏽‍💻"
    _ = try await fixture.store.persist(id: kept.id, accountID: accountID, text: text, generation: 1)
    fixture.lastOpened.save(
      .init(gistID: nil, filename: blank.filename, draftID: blank.id), accountID: accountID)
    let library = fixture.library
    await library.start()
    #expect(library.loadedFile == nil)
    #expect(library.localDrafts.map(\.id) == [kept.id])
    #expect(library.state.gists.map(\.id) == [kept.id.uuidString])
    let stored = try await fixture.store.drafts(accountID: accountID)
    #expect(stored.first { $0.id == kept.id }?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func returningToTheAppPublishesEveryLeftNoteWithUnpublishedEdits() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    _ = try await fixture.stageEdit(gistID: "a", filename: "README.md", text: "One, edited")
    _ = try await fixture.stageEdit(gistID: "b", filename: "README.md", text: "Two, edited")
    await fixture.library.start()
    await fixture.library.publishUnsyncedEdits()
    #expect(fixture.remote("a", "README.md") == "One, edited")
    #expect(fixture.remote("b", "README.md") == "Two, edited")
    #expect(fixture.publishes.sorted() == ["PATCH /gists/a", "PATCH /gists/b"])
  }

  @Test func everyOwnedRowDeletesInAnyStateAndSomeoneElsesCannot() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "An owned gist", files: ["README.md": "Mine"])
      $0.addGist(
        id: "shared", description: "A friend's gist", files: ["README.md": "Theirs"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    let accountID = fixture.account.id
    let orphan = try await fixture.stageEdit(
      gistID: "gone", filename: "README.md", text: "An edit to a gist deleted elsewhere")
    let local = try await fixture.store.newGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id)
    _ = try await fixture.store.persist(
      id: local.id, accountID: accountID, text: "A gist never published", generation: 1)
    let library = fixture.library
    await library.start()
    let orphanRow = try #require(library.state.gists.first { $0.id == orphan.id.uuidString })
    #expect(orphanRow.isRecovery)
    await library.refresh()
    #expect(library.state.gists.first { $0.id == orphanRow.id }?.updatedAt == orphan.updatedAt)

    // A new gist's row is its own as soon as it publishes.
    await library.open(.new)
    let created = try #require(library.loadedFile?.draft)
    #expect(library.loadedFile.map(library.details(for:))?.shareURL == nil)
    _ = try await library.persist(
      draftID: created.id, accountID: accountID, text: "Just published", generation: 1)
    let published = try await library.publish(draftID: created.id, accountID: accountID)
    let gistID = try #require(published.gistID)
    let shareURL = try #require(library.loadedFile.map(library.details(for:))?.shareURL)
    #expect(shareURL.absoluteString.hasPrefix("https://gistpad.dev/#/share/\(gistID)/"))
    #expect(library.state.selectedID == gistID)
    #expect(library.deletion(forRow: created.id.uuidString) == .delete(gistID: gistID))
    for id in ["gone", "unknown", "shared"] {
      #expect(library.deletion(forRow: id) == nil)
    }

    await library.open(.draft(id: orphan.id))
    #expect(library.loadedFile?.isRecovery == true)
    let owned = [orphanRow.id, local.id.uuidString, "a", gistID]
    for rowID in owned {
      _ = try await library.perform(try #require(library.deletion(forRow: rowID)))
    }
    #expect(library.state.selectedID != orphanRow.id)
    await library.refresh()
    let rows = Set(library.state.gists.map(\.id))
    #expect(rows.isDisjoint(with: owned) && rows.contains("shared"))
    #expect(fixture.server.gists.map(\.id) == ["shared"])
    #expect(
      fixture.server.requests.filter { $0.hasPrefix("DELETE") }
        == ["DELETE /gists/a", "DELETE /gists/\(gistID)"])
    let stored = Set(try await fixture.store.drafts(accountID: accountID).map(\.id))
    #expect(stored.isDisjoint(with: [orphan.id, local.id, created.id]))
  }

  @Test func deletingALibraryGistRemovesItsRowAndDraftsAndOpensNothing() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "A published note", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    await library.open(.gist(id: "a"))
    let draft = try #require(library.loadedFile?.draft)
    _ = try await library.persist(
      draftID: draft.id, accountID: draft.accountID, text: "An accepted edit", generation: 1)
    _ = try await library.publish(draftID: draft.id, accountID: draft.accountID)
    #expect(library.deletion(forRow: "a") == .delete(gistID: "a"))
    _ = try await library.perform(.delete(gistID: "a"))
    #expect(fixture.server.requests.filter { $0.hasPrefix("DELETE") } == ["DELETE /gists/a"])
    #expect(fixture.server.gists.isEmpty)
    #expect(library.loadedFile == nil)
    #expect(library.state.selectedID == nil)
    #expect(library.deletion(forRow: "a") == nil)
    #expect(library.state.gists.isEmpty)
    #expect(try await fixture.store.drafts(accountID: fixture.account.id).isEmpty)
    let relaunched = fixture.relaunch()
    await relaunched.start()
    #expect(relaunched.state.gists.isEmpty)
    #expect(relaunched.loadedFile == nil)
  }

  // MARK: Account

  @Test func signOutRetainsExactDraftsAndRestoresTheSameAccount() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Kept on this iPhone", files: ["README.md": "Base"])
    }
    let text = "Private e\u{301}\r\n日本語 👩🏽‍💻"
    let draft = try await fixture.stageEdit(gistID: "a", filename: "README.md", text: text)
    let library = fixture.library
    await library.start()
    #expect(library.loadedFile?.draft?.id == draft.id)
    _ = try await library.perform(.signOut)
    #expect(library.account == nil)
    #expect(library.loadedFile == nil)
    #expect(library.cachedLibrary == nil)
    #expect(library.state.gists.isEmpty)
    #expect(library.state.loadState == .signedOut)
    let kept = try await fixture.store.drafts(accountID: fixture.account.id)
    #expect(kept.first { $0.id == draft.id }?.text.utf8.elementsEqual(text.utf8) == true)
    await library.signIn()
    #expect(library.account?.id == fixture.account.id)
    #expect(library.loadedFile?.draft?.id == draft.id)
    #expect(library.loadedFile?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func anotherAccountSigningInWaitsAndKeepsTheOriginalDrafts() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Original account", files: ["README.md": "Base"])
    }
    let text = "日本語 e\u{301}\r\n**Private draft**"
    let local = try await fixture.stageEdit(gistID: "a", filename: "README.md", text: text)
    let library = fixture.library
    await library.start()
    let other = UUID()
    try fixture.signInNext(as: other, login: FixtureServer.someoneElse.login)
    await library.signIn()
    #expect(library.account?.id == fixture.account.id)
    #expect(library.pendingAccount?.id == other)
    #expect(library.loadedFile?.accountID == fixture.account.id)
    guard case .reconnectRequired = library.state.loadState else {
      Issue.record("An account switch must not silently adopt another account.")
      return
    }
    library.keepCurrentAccount()
    #expect(library.account?.id == fixture.account.id)
    #expect(library.pendingAccount == nil)
    let kept = try await fixture.store.drafts(accountID: fixture.account.id)
    #expect(kept.first { $0.id == local.id }?.text.utf8.elementsEqual(text.utf8) == true)
    #expect(try await fixture.store.drafts(accountID: other).isEmpty)
  }

  // MARK: Daily notes

  @Test func coldStartOpensNothingAndAnUntouchedTodayDoesNotPublish() async throws {
    let fixture = try await LibraryFixture()
    let library = fixture.library
    await library.start()
    #expect(library.loadedFile == nil)
    #expect(try await fixture.store.drafts(accountID: fixture.account.id).isEmpty)
    await library.open(.today())
    let file = try #require(library.loadedFile)
    let draft = try #require(file.draft)
    #expect(file.filename == DailyNote.Day().filename)
    #expect(file.editingRequestID != nil)
    #expect(draft.isDiscardableBlank)
    let session = FileSession(
      file: file, draft: draft, library: library, autosaveDelay: .milliseconds(1))
    #expect(!session.hasUnpublishedChanges)
    #expect(session.autosave(foreground: true) == nil)
    await session.publish(reason: .background)
    #expect(fixture.publishes.isEmpty)
    session.requestCreationFocus()
    #expect(session.mode == .edit)
    session.mode = .preview
    session.requestCreationFocus()
    #expect(session.mode == .preview, "A render does not repeat the same editing request.")
    await library.open(.today())
    session.adoptPresentation(try #require(library.loadedFile))
    session.requestCreationFocus()
    #expect(session.mode == .edit, "A fresh Today action focuses the retained editor again.")
  }

  @Test func twoTodayTapsMakeOneDailyNote() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    let first = Task { await library.open(.today()) }
    let second = Task { await library.open(.today()) }
    await first.value
    await second.value
    let today = try #require(library.loadedFile?.draft)
    #expect(today.filename == DailyNote.Day().filename)
    _ = try await library.persist(
      draftID: today.id, accountID: today.accountID, text: "- [ ] One task", generation: 1)
    _ = try await library.publish(draftID: today.id, accountID: today.accountID)
    await library.open(.gist(id: "a"))
    await library.open(.today())
    #expect(library.loadedFile?.draft?.id == today.id)
    let dailies = try await fixture.store.drafts(accountID: fixture.account.id).filter {
      $0.description == DailyNote.gistDescription
    }
    #expect(dailies.map(\.id) == [today.id])
    #expect(fixture.publishes == ["POST /gists"])
    #expect(fixture.server.gists.filter(\.isDailyNote).map { Array($0.files.keys) }
      == [[today.filename]])
  }

  @Test func anExplicitTodayActionPinsTheRequestedDayWithoutAnInterstitial() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Last chosen", files: ["README.md": "Text"])
    }
    let library = fixture.library
    await library.start()
    #expect(library.loadedFile?.gist?.id == "a")
    let target = DailyNote.Day(
      date: Date(timeIntervalSince1970: 1_790_208_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    await library.open(.today(target))
    #expect(library.loadedFile?.draft?.filename == target.filename)
    #expect(library.loadedFile?.editingRequestID != nil)
  }

  @Test func dailyRowsShowTheirDayAndTaskProgressThroughEditingAndPublishing() async throws {
    let today = DailyNote.filename()
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [
          today: "- [x] One\n- [ ] Two\nA third line stays out of the excerpt.",
          "2026-10-23.md": "An earlier day",
        ])
    }
    let draft = try await fixture.stageEdit(
      gistID: "daily", filename: "2026-10-24.md", text: "- [ ] A retained task")
    let library = fixture.library
    await library.start()
    // Opening today reads its text, so its row and the Today button count its tasks.
    await library.open(.today())
    let todayRow = try #require(
      library.state.unfilteredGists(in: .dailyNotes).first { $0.id == "daily/\(today)" })
    #expect(todayRow.dailyDate == DailyNote.date(filename: today))
    #expect(todayRow.progress == .init(completed: 1, total: 2))
    #expect(library.state.today.progress == .init(completed: 1, total: 2))
    #expect(library.state.dailyNoteCount == 3)

    // A day that's new on this phone keeps its one row through editing and publishing.
    let rowID = "daily/2026-10-24.md"
    await library.openRow(id: rowID)
    let fileID = try #require(library.loadedFile?.id)
    let text = "- [x] A retained task\n- [ ] A new task"
    _ = try await library.persist(
      draftID: draft.id, accountID: draft.accountID, text: text, generation: draft.generation + 1)
    let row = try #require(library.state.gists.first { $0.id == rowID })
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(row.isOverdue)
    _ = try await library.publish(draftID: draft.id, accountID: draft.accountID)
    #expect(fixture.remote("daily", "2026-10-24.md") == text)
    #expect(fixture.publishes == ["PATCH /gists/daily"])
    #expect(library.loadedFile?.id == fileID)
    #expect(library.state.selectedID == rowID)
    #expect(library.state.dailyNoteCount == 3)
    #expect(library.state.gists.filter { $0.id == rowID }.count == 1)
    #expect(!library.state.gists.contains { $0.id == draft.id.uuidString })
  }

  @Test func unfilteredDailyRowsResolveTheirGistAndRefreshOverdueOnCalendarChanges() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: ["2026-01-02.md": "- [ ] Carried over"])
    }
    let library = fixture.library
    await library.start()
    let rowID = "daily/2026-01-02.md"
    // GitHub lists gists without their text, so a day's tasks are known once it's been opened.
    await library.openRow(id: rowID)
    #expect(library.gistID(forRow: rowID) == "daily")
    #expect(library.gistID(forRow: "daily/2026-01-03.md") == nil)
    let index = try #require(library.state.gists.firstIndex { $0.id == rowID })
    #expect(library.state.gists[index].isOverdue)
    // A row projected before midnight is stale until the calendar changes.
    library.state.gists[index].isOverdue = false
    library.updateCalendar()
    #expect(library.state.gists[index].isOverdue)
  }

  @Test func dailyRowsOpenAndDeleteTheirExactFile() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: ["2026-10-23.md": "The alpha day", "2026-10-24.md": "The beta day"])
    }
    let library = fixture.library
    await library.start()
    await library.openRow(id: "daily/2026-10-24.md")
    #expect(library.loadedFile?.filename == "2026-10-24.md")
    #expect(library.loadedFile?.text == "The beta day")
    #expect(library.state.selectedID == "daily/2026-10-24.md")
    await library.openRow(id: "daily/2026-10-23.md")
    #expect(library.loadedFile?.text == "The alpha day")
    #expect(library.state.selectedID == "daily/2026-10-23.md")
    await library.open(.gist(id: "daily", filename: "2026-10-24.md"))
    #expect(library.state.selectedID == "daily/2026-10-24.md")
    #expect(library.loadedFile?.rowID == "daily/2026-10-24.md")
    #expect(
      library.deletion(forRow: "daily/2026-10-24.md")
        == .deleteFile(gistID: "daily", filename: "2026-10-24.md"),
      "A Daily row deletes only its own file.")
  }

  @Test func deletingADailyNoteRemovesOnlyItsFileOrTheGistWithItsLastFile() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "daily", filename: "2026-10-23.md", draftID: nil)
    ) {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: ["2026-10-23.md": "The alpha day", "2026-10-24.md": "The beta day"])
    }
    let library = fixture.library
    await library.start()
    #expect(library.state.dailyNoteCount == 2)
    _ = try await library.perform(try #require(library.deletion(forRow: "daily/2026-10-24.md")))
    #expect(library.state.dailyNoteCount == 1)
    #expect(library.state.gists.map(\.id) == ["daily/2026-10-23.md"])
    #expect(fixture.remote("daily", "2026-10-24.md") == nil)
    #expect(fixture.remote("daily", "2026-10-23.md") == "The alpha day")
    _ = try await library.perform(try #require(library.deletion(forRow: "daily/2026-10-23.md")))
    #expect(fixture.server.gists.isEmpty)
    #expect(!library.state.gists.contains { $0.gistID == "daily" })
  }

  @Test func deletingTheOpenTodayFromTheListKeepsItDeleted() async throws {
    let today = DailyNote.filename()
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [today: "Today's words", "2026-10-23.md": "An earlier day"])
    }
    let library = fixture.library
    await library.start()
    await library.open(.today())
    #expect(library.loadedFile?.filename == today)
    _ = try await library.apply(
      try #require(library.deletion(forRow: "daily/\(today)")), accountID: fixture.account.id)
    #expect(library.loadedFile == nil)
    #expect(fixture.remote("daily", today) == nil)
    #expect(!library.state.gists.contains { $0.filename == today })
    #expect(try await fixture.store.drafts(accountID: fixture.account.id).allSatisfy {
      $0.filename != today
    })
  }

  @Test func aDayThatPublishesWhileItsDeletionWaitsRemovesOnlyThatDay() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
    }
    let accountID = fixture.account.id
    // An earlier day written offline, before there was a daily notes gist.
    let staged = try await fixture.store.newGistDraft(
      accountID: accountID, githubUserID: FixtureServer.you.id, filename: "2026-10-23.md",
      description: DailyNote.gistDescription)
    let earlier = try await fixture.store.persist(
      id: staged.id, accountID: accountID, text: "The alpha day", generation: staged.generation + 1)
    let library = fixture.library
    await library.start()
    // Its deletion is confirmed, then Today publishes it and joins the gist it creates.
    await library.open(.today())
    let gistID = try #require(fixture.server.gists.first(where: \.isDailyNote)?.id)
    let today = try #require(library.loadedFile?.draft)
    #expect(today.gistID == gistID)
    _ = try await library.persist(
      draftID: today.id, accountID: accountID, text: "- [ ] Today's task",
      generation: today.generation + 1)
    _ = try await library.publish(draftID: today.id, accountID: accountID)
    #expect(fixture.remote(gistID, "2026-10-23.md") == "The alpha day")

    let settled = try await library.settledDeletionAction(
      .discardLocalCopy(draftID: earlier.id, generation: earlier.generation),
      confirmedWithoutGist: true, accountID: accountID)
    try #require(
      settled == .deleteFile(gistID: gistID, filename: "2026-10-23.md"),
      "A day that reached GitHub after its deletion was confirmed deletes only its file.")
    _ = try await library.perform(settled)
    #expect(fixture.remote(gistID, "2026-10-23.md") == nil)
    #expect(fixture.remote(gistID, today.filename) == "- [ ] Today's task")
  }
}

@Suite(.serialized)
@MainActor
struct RootViewTests {
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
    let fixture = try await LibraryFixture(autosave: false) {
      $0.addGist(
        id: "reading", description: "Reading list",
        files: ["README.md": source, "Calendar.md": "# A second file"])
      $0.addGist(id: "other", description: "Another note", files: ["README.md": other])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact, mode: .preview)
    defer { await host.close() }
    var retained: UITextView?
    for id in ["reading", "other", "reading"] {
      let text = id == "reading" ? source : other
      host.library.select(rowID: id)
      try await host.waitUntil {
        host.library.visibleFile?.gist?.id == id && host.editor(text: text) != nil
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
        host.layout.select(.preview)
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
              == NSRange(location: Syntax.contentStart(in: text), length: 0))
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
    let fixture = try await LibraryFixture {
      $0.addGist(id: "kept", description: "Kept", files: ["README.md": "A real note"])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
    defer { await host.close() }
    // Creating is local, so it works offline.
    fixture.fail()
    await host.library.open(.new)
    let first = try #require(host.library.visibleFile?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    #expect(host.editor(text: "")?.selectedRange == NSRange(location: 0, length: 0))
    try await host.waitForKeyboard(visible: true)
    fixture.restore()
    host.pending.link = .gist(id: "kept", filename: nil)
    try await host.waitUntil {
      host.pending.link == nil && host.editor(text: "A real note") != nil
        && !host.library.localDrafts.contains { $0.id == first.id }
    }
    #expect(host.library.state.selectedID == "kept")

    await host.library.open(.new)
    let second = try #require(host.library.visibleFile?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    host.returnToLibrary()
    try await host.waitUntil {
      host.isLibraryVisible && !host.library.localDrafts.contains { $0.id == second.id }
    }
    #expect(host.library.loadedFile == nil)
    let stored = try await fixture.store.drafts(accountID: fixture.account.id).map(\.id)
    #expect(!stored.contains(first.id) && !stored.contains(second.id))
    #expect(fixture.publishes.isEmpty)
  }

  @Test(arguments: [true, false])
  func returningToLibraryPublishesTheOutgoingNoteAndKeepsItsEditor(autosave: Bool) async throws {
    let fixture = try await LibraryFixture(autosave: autosave) {
      $0.addGist(id: "a", description: "Current", files: ["README.md": "Current source"])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
    defer { await host.close() }
    await host.library.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 0, length: 0)
    editor.insertText("Local ")
    try await host.waitUntil {
      host.library.localDrafts.first { $0.gistID == "a" }?.generation == 1
    }
    host.returnToLibrary()
    // Well before autosave's quiet timer.
    try await host.waitUntil(timeout: .seconds(1)) {
      fixture.remote("a", "README.md") == "Local Current source"
    }
    try await host.waitUntil { host.isLibraryVisible }
    #expect(fixture.publishes == ["PATCH /gists/a"])
    #expect(host.library.state.selectedID == nil)
    #expect(!editor.isFirstResponder)
    let selection = editor.selectedRange
    host.pending.link = .gist(id: "a", filename: nil)
    try await host.waitUntil {
      host.pending.link == nil && host.editor(text: "Local Current source") === editor
        && !host.isLibraryVisible
    }
    #expect(editor.selectedRange == selection)
  }

  @Test func switchingNotesMidCompositionKeepsAndPublishesTheComposedText() async throws {
    let fixture = try await LibraryFixture(autosave: false) {
      $0.addGist(id: "a", description: "First note", files: ["README.md": "First note source"])
      $0.addGist(id: "b", description: "Second note", files: ["README.md": "Second note source"])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    host.library.select(rowID: "a")
    try await host.waitUntil { host.editor(text: "First note source") != nil }
    let first = try #require(host.editor(text: "First note source"))
    try #require(first.becomeFirstResponder())
    first.selectedRange = NSRange(location: 0, length: 0)
    first.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
    try #require(first.markedTextRange != nil)
    host.library.select(rowID: "b")
    try await host.waitUntil { host.editor(text: "Second note source") != nil }
    #expect(first.markedTextRange == nil)
    #expect(first.text == "にほんごFirst note source")
    try await host.waitUntil { fixture.remote("a", "README.md") == "にほんごFirst note source" }
    #expect(fixture.publishes == ["PATCH /gists/a"])
  }

  @Test func startingTodayFocusesTheCaretAfterItsDurableInitialContent() async throws {
    let fixture = try await LibraryFixture()
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.library.open(.today())
    let draft = try #require(host.library.visibleFile?.draft)
    #expect(!draft.text.isEmpty)
    try await host.waitUntil { host.editor(text: draft.text)?.isFirstResponder == true }
    let editor = try #require(host.editor(text: draft.text))
    #expect(editor.selectedRange == NSRange(location: draft.text.utf16.count, length: 0))
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aColdLinkWaitsForRestorationAndOpensTheExactFile() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "b", description: "Routed note",
        files: ["README.md": "Text", "Ideas.md": "Routed file source"])
    }
    let pending = PendingLink()
    pending.link = .gist(id: "b", filename: "Ideas.md")
    let host = try await NavigationHost(fixture: fixture, pending: pending)
    defer { await host.close() }
    try await host.waitUntil {
      pending.link == nil && host.editor(text: "Routed file source") != nil
    }
    #expect(host.library.loadedFile?.filename == "Ideas.md")
    #expect(host.library.loadedFile?.gist?.id == "b")
  }

  /// A widget's Today opens on a folded phone at a cold launch without waiting for GitHub: at once
  /// when you've written in it on this iPhone, and behind its placeholder while GitHub stages it.
  @Test(arguments: [true, false])
  func aColdTodayLinkOpensWithoutWaitingForGitHub(writtenOnThisIPhone: Bool) async throws {
    let today = DailyNote.filename()
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [DailyNote.filename(date: .now - 86_400): "- [x] Yesterday's task\n"])
    }
    var text = "# \(today.dropLast(3))\n\n"
    if writtenOnThisIPhone {
      await fixture.library.start()
      text = "Written on this iPhone"
      _ = try await fixture.stageEdit(gistID: "daily", filename: today, text: text)
    }
    let github = fixture.hold("GET /gists")
    let pending = PendingLink()
    pending.link = .today
    let host = try await NavigationHost(
      fixture: fixture, library: fixture.relaunch(), pending: pending, sizeClass: .compact,
      waitsForStart: false)
    defer {
      github.open()
      await host.close()
    }
    try await github.arrival()
    try await host.waitUntil { !host.isLibraryVisible }
    if !writtenOnThisIPhone { github.open() }
    try await host.waitUntil {
      pending.link == nil && host.library.visibleFile?.filename == today
        && host.editor(text: text)?.isFirstResponder == true
    }
  }

  /// Opening early doesn't mean deciding from a stale library: today started on the web since
  /// the last launch opens from GitHub while the launch's refresh is still out.
  @Test func aColdTodayLinkOpensTodayFromTheWebOverAStaleLibrary() async throws {
    let today = DailyNote.filename()
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [DailyNote.filename(date: .now - 86_400): "- [x] Yesterday's task\n"])
      $0.addGist(id: "a", description: "Last opened", files: ["README.md": "Last opened"])
    }
    await fixture.library.start()
    fixture.server.edit("daily", files: [today: "Started on the web"])
    let refresh = fixture.hold("GET /gists/starred")
    let pending = PendingLink()
    pending.link = .today
    let host = try await NavigationHost(
      fixture: fixture, library: fixture.relaunch(), pending: pending, sizeClass: .compact,
      waitsForStart: false)
    defer {
      refresh.open()
      await host.close()
    }
    try await refresh.arrival()
    try await host.waitUntil {
      pending.link == nil && host.library.visibleFile?.filename == today
        && host.editor(text: "Started on the web") != nil
    }
  }

  @Test func aNewGistLinkOpensABlankNoteReadyToWrite() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "Existing", files: ["README.md": "Existing source"])
    }
    let pending = PendingLink()
    pending.link = .newGist
    let host = try await NavigationHost(fixture: fixture, pending: pending)
    defer { await host.close() }
    try await host.waitUntil { pending.link == nil && host.editor(text: "")?.isFirstResponder == true }
    let draft = try #require(host.library.visibleFile?.draft)
    #expect(host.library.localDrafts.contains { $0.id == draft.id })
    #expect(host.library.visibleFile?.gist == nil)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aFailedOpenShowsItsOwnTitleAndRetryInsteadOfThePreviousEditor() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "Previous", files: ["README.md": "Previous source"])
      $0.addGist(
        id: "b", description: "Requested",
        files: ["README.md": "Text", "Other.md": "Retried source"])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.library.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "Previous source") != nil }
    fixture.fail("GET /gists/b")
    await host.library.open(.gist(id: "b", filename: "Other.md", rowID: "result-b"))
    try await host.waitUntil {
      host.descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }.contains("Requested")
    }
    #expect(host.editor(text: "Previous source") == nil)
    fixture.restore()
    try await host.library.open(#require(host.library.opening).request)
    try await host.waitUntil { host.editor(text: "Retried source") != nil }
    #expect(accessibilityElement("note-open-retry", in: host.window) == nil)
    #expect(host.library.loadedFile?.gist?.id == "b")
    #expect(host.library.state.selectedID == "b")
    #expect(host.library.loadedFile?.filename == "Other.md")
  }

  @Test func sourceIntelligenceOpensTheLiveSheetForTheRetainedEditor() async throws {
    let fixture = try await LibraryFixture(autosave: false) {
      $0.addGist(
        id: "a", description: "A retained thought", files: ["README.md": "A little room to think."])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.library.open(.gist(id: "a"))
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

/// The app's root view in a real window, around a fixture library.
@MainActor
private struct NavigationHost {
  let library: Library
  let window: UIWindow
  let pending: PendingLink
  let layout: LayoutPreferences
  private let suite: String
  private let previousWindow: UIWindow?

  init(
    fixture: LibraryFixture, library: Library? = nil, pending: PendingLink = PendingLink(),
    sizeClass: UIUserInterfaceSizeClass? = nil, mode: FileMode = .edit, waitsForStart: Bool = true
  ) async throws {
    self.library = library ?? fixture.library
    self.pending = pending
    suite = "RootView-\(UUID())"
    layout = LayoutPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    layout.select(mode)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previousWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    let sceneBounds = scene.effectiveGeometry.coordinateSpace.bounds
    // A compact host is a phone even when the simulator is an open Duo.
    let width: CGFloat =
      switch sizeClass {
      case .regular: 1180
      case .compact: min(sceneBounds.width, 440)
      default: sceneBounds.width
      }
    window.frame = CGRect(
      origin: sceneBounds.origin, size: CGSize(width: width, height: sceneBounds.height))
    if let sizeClass { window.traitOverrides.horizontalSizeClass = sizeClass }
    window.rootViewController = UIHostingController(
      rootView: RootView(library: self.library, layout: layout, pending: pending))
    window.makeKeyAndVisible()
    guard waitsForStart else { return }
    let library = self.library
    try await waitUntil {
      library.state.loadState == .ready && library.cachedLibrary != nil && !library.isStarting
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

  /// The file's Edit, Preview (and Split, when wide) control.
  var picker: UISegmentedControl? {
    descendants.compactMap { $0 as? UISegmentedControl }.last
  }

  /// Pops the pushed file the way the system back button does on iPhone.
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
          load: \(library.state.loadState)
          loaded: \(String(describing: library.loadedFile?.id))
          presented: \(String(describing: library.visibleFile?.id))
          opening: \(String(describing: library.opening))
          error: \(String(describing: library.openError))
          link: \(String(describing: pending.link))
          library visible: \(isLibraryVisible)
          editors: \(descendants.compactMap { ($0 as? UITextView)?.text })
          titles: \(descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title })
          """, named: "navigation-timeout.txt")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "navigation-timeout.png", as: .png)
        Issue.record("The mounted library did not reach its expected presentation.")
        throw HostError.presentationTimedOut
      }
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  func close() async {
    window.rootViewController?.dismiss(animated: false)
    // A closing sheet hands focus back to the file it came from, a beat after it's gone.
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
