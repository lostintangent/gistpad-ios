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

  // MARK: Launching

  @Test func launchingShowsYourGistsAndOpensNothing() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    #expect(phone.rows.map(\.id) == ["a"])
    #expect(phone.onScreen == nil)
    #expect(phone.publishes.isEmpty)
  }

  @Test func launchingAgainReopensYourLastFileAndPublishesEditsLeftBehind() async throws {
    let phone = try await Phone(lastFile: .init(gistID: "a", filename: "Ideas.md", draftID: nil)) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One", "Ideas.md": "Ideas"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
      $0.addGist(id: "c", description: "Third", files: ["README.md": "Three"])
    }
    try await phone.leftover("b", text: "Two, edited")
    try await phone.leftover("c", text: "Three, edited")
    await phone.launch()
    #expect(phone.onScreen == "Ideas")
    #expect(phone.publishes.sorted() == ["PATCH /gists/b", "PATCH /gists/c"])
    #expect(phone.onGitHub("b") == "Two, edited")
    #expect(phone.onGitHub("c") == "Three, edited")
    await phone.library.refresh()
    #expect(phone.onScreen == "Ideas")
  }

  @Test func launchingOfflineShowsYourGistsAndLastFileFromThisIPhone() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    try await phone.open(.gist(id: "a"))
    phone.goOffline()
    await phone.relaunch()
    #expect(phone.rows.map(\.id) == ["a"])
    #expect(phone.onScreen == "One")
  }

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
    #expect(library.loadedFile?.draft.text == "Original text")
    #expect(library.state.query == "Original")
    #expect(library.state.selectedTagIDs == ["ideas"])
    #expect(library.state.selectedID == "a")
  }

  /// A launch link can open a gist before GitHub's list arrives, and it stays selected once its row does.
  @Test func aGistOpenedBeforeTheListArrivesStaysSelected() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "Opened early", files: ["README.md": "Text"])
    }
    let library = fixture.library
    let list = fixture.hold("GET /gists/starred")
    let start = Task { await library.start() }
    try await list.arrival()
    await library.open(.gist(id: "a"))
    #expect(library.state.selectedID == "a")
    list.open()
    await start.value
    #expect(library.state.selectedID == "a")
    #expect(library.loadedFile?.rowID == "a")
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
    #expect(library.visibleFile?.draft.text == "Second source")
    #expect(library.activeSession?.file.gist?.id == "b")
    await Task.yield()
    #expect(fixture.server.requests == requests)
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
    let draft = file.draft
    let session = FileSession(file: file, library: library)
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

  @Test func openingAFileOfflineThatsNeverBeenOpenedFails() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    phone.goOffline()
    await phone.library.open(.gist(id: "a"))
    #expect(phone.library.opening?.failure != nil)
    #expect(phone.onScreen == nil)
  }

  @Test func openingTodayFillsInTheDailyTemplate() async throws {
    let phone = try await Phone {
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: ["template.md": "# {{date}}\n\n- [ ] Plan {{date}}\n"])
    }
    await phone.launch()
    try await phone.open(.today())
    let date = DailyNote.Day().filename.dropLast(3)
    #expect(phone.onScreen == "# \(date)\n\n- [ ] Plan \(date)\n")
    #expect(phone.publishes.isEmpty)
  }

  @Test(arguments: [false, true])
  func leavingAnUntouchedFilePublishesNothing(today: Bool) async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    await phone.leave(try await phone.open(today ? .today() : .gist(id: "a")))
    await phone.returnToApp()
    #expect(phone.publishes.isEmpty)
    #expect(phone.rows.map(\.id) == ["a"])
    #expect(phone.days.isEmpty)
  }

  // MARK: Writing

  @Test func typingIsSavedOnThisIPhoneBeforeItPublishes() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    let last = "One, 日本語 👨‍👩‍👧‍👦"
    try await phone.type("One,", "One, 日本", last, in: a)
    #expect(a.saveState == .savedLocally)
    #expect(phone.publishes.isEmpty)
    phone.goOffline()
    await phone.relaunch()
    #expect(phone.onScreen?.utf8.elementsEqual(last.utf8) == true)
  }

  @Test(arguments: [true, false])
  func autosavePublishesOnceTypingStops(autosave: Bool) async throws {
    let phone = try await Phone(autosave: autosave) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("One, typed", in: a)
    let older = a.updateAutosave()
    try await phone.type("One, typed again", in: a)
    let latest = a.updateAutosave()
    #expect((latest != nil) == autosave)
    #expect(phone.publishes.isEmpty)
    await older?.value
    await latest?.value
    #expect(phone.publishes == (autosave ? ["PATCH /gists/a"] : []))
    #expect(phone.onGitHub("a") == (autosave ? "One, typed again" : "One"))
  }

  @Test func leavingTheAppPublishesTheOpenFile() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("One, typed", in: a)
    await phone.leaveApp()
    #expect(phone.onGitHub("a") == "One, typed")
    #expect(a.saveState == .savedToGitHub)
  }

  @Test func typingDuringAPublishPublishesNext() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("First", in: a)
    let gate = phone.fixture.hold("PATCH /gists/a")
    let publishing = Task { await a.publish() }
    try await gate.arrival()
    try await phone.type("Second", in: a)
    gate.open()
    await publishing.value
    #expect(phone.onGitHub("a") == "First")
    #expect(phone.onScreen == "Second")
    #expect(a.saveState == .savedLocally)
    await phone.leave(a)
    #expect(phone.onGitHub("a") == "Second")
  }

  enum Moment: CaseIterable { case autosave, leavingTheFile, leavingTheApp, returningToTheApp }

  @Test(arguments: Moment.allCases)
  func anEditThatCouldntPublishPublishesAtTheNextChance(_ moment: Moment) async throws {
    let phone = try await Phone()
    await phone.launch()
    phone.goOffline()
    let today = try await phone.open(.today())
    try await phone.type("# Today\n\n- [ ] Walk", in: today)
    await today.publish()
    #expect(today.saveState == .failed(.network))
    phone.goOnline()
    switch moment {
    case .autosave:
      try await phone.type("# Today\n\n- [ ] Walk the dog", in: today)
      await today.updateAutosave()?.value
    case .leavingTheFile: await phone.leave(today)
    case .leavingTheApp: await phone.leaveApp()
    case .returningToTheApp: await phone.returnToApp()
    }
    #expect(phone.publishes == ["POST /gists"])
    #expect(today.saveState == .savedToGitHub)
    let daily = try #require(phone.github.gists.first { $0.isDailyNote })
    #expect(daily.files[DailyNote.Day().filename]?.content == today.editor.text)
    #expect(daily.isPublic == false)
  }

  @Test func aNewGistNamedOfflineIsCreatedWhenYouReturn() async throws {
    let phone = try await Phone()
    await phone.launch()
    phone.goOffline()
    let new = try await phone.open(.new)
    #expect(phone.onScreen == "")
    _ = try await phone.library.apply(
      .renameLocal(new.draft, title: "Ideas"), accountID: phone.accountID)
    await phone.leave(new)
    #expect(phone.rows.map(\.title) == ["Ideas"])
    #expect(phone.publishes.isEmpty)
    phone.goOnline()
    await phone.returnToApp()
    let gist = try #require(phone.github.gists.first)
    #expect(gist.description == "Ideas")
    #expect(phone.publishes == ["POST /gists"])
    #expect(phone.rows.map(\.id) == [gist.id])
  }

  // MARK: Returning to the app

  @Test func returningToTheAppPublishesEditsAndRefreshesTheOpenFile() async throws {
    let phone = try await Phone {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    try await phone.open(.gist(id: "a"))
    let b = try await phone.open(.gist(id: "b"))
    try await phone.type("Two, typed", in: b)
    phone.goOffline()
    try await phone.open(.gist(id: "a"))
    phone.goOnline()
    phone.webEdits("a", ["README.md": "One, from the web"])
    await phone.returnToApp()
    #expect(phone.onGitHub("b") == "Two, typed")
    #expect(phone.onScreen == "One, from the web")
  }

  @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost])
  func returningToTheAppRetriesAFailedRefresh(_ failure: URLError.Code) async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    try await phone.open(.gist(id: "a"))
    phone.github.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    phone.dropRequests(failure)
    await phone.library.refresh()
    #expect(phone.rows.map(\.id) == ["a"])
    #expect(phone.onScreen == "One")
    #expect(phone.status == (failure == .notConnectedToInternet ? "Couldn't update your gists" : nil))
    phone.goOnline()
    let list = phone.fixture.hold("GET /gists/starred")
    let returning = Task { await phone.returnToApp() }
    try await list.arrival()
    #expect(phone.status == "Checking")
    list.open()
    await returning.value
    #expect(Set(phone.rows.map(\.id)) == ["a", "b"])
    #expect(phone.status == nil)
  }

  @Test func aGistDeletedOnTheWebLeavesTheListOnRefresh() async throws {
    let phone = try await Phone {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    try await phone.webDeletes("a")
    #expect(Set(phone.rows.map(\.id)) == ["a", "b"])
    await phone.library.refresh()
    #expect(phone.rows.map(\.id) == ["b"])
  }

  // MARK: Conflicts

  @Test func publishingOverAWebEditShowsBothVersionsAndKeepMinePublishesIt() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("Mine", in: a)
    phone.webEdits("a", ["README.md": "Theirs"])
    await a.publish()
    let review = try a.reviewContext()
    #expect(review.conflict.local == "Mine")
    #expect(review.conflict.remote == "Theirs")
    #expect(phone.onGitHub("a") == "Theirs")
    try await a.applyReview(review, text: "Mine", publishes: true)
    #expect(phone.onGitHub("a") == "Mine")
    #expect(a.saveState == .savedToGitHub)
  }

  @Test func usingGitHubsVersionTakesItWithoutPublishing() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("Mine", in: a)
    phone.webEdits("a", ["README.md": "Theirs"])
    await a.publish()
    try await a.applyReview(a.reviewContext(), text: "Theirs", publishes: false)
    #expect(phone.onScreen == "Theirs")
    #expect(a.saveState == .savedToGitHub)
    #expect(phone.publishes.isEmpty)
  }

  @Test func keepingMineRestoresAFileDeletedOnTheWeb() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One", "Other.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a", filename: "README.md"))
    try await phone.type("Mine", in: a)
    phone.webEdits("a", ["README.md": nil])
    await a.publish()
    let review = try a.reviewContext()
    #expect(review.conflict.remote == nil)
    try await a.applyReview(review, text: "Mine", publishes: true)
    #expect(phone.onGitHub("a") == "Mine")
  }

  @Test func editsToAGistDeletedOnTheWebStayOnThisIPhoneUntilYouDeleteThem() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    phone.goOffline()
    try await phone.type("Mine", in: a)
    await phone.leave(a)
    phone.goOnline()
    try await phone.webDeletes("a")
    await phone.library.refresh()
    let row = try #require(phone.rows.first)
    #expect(phone.rows.count == 1)
    #expect(row.isRecovery)
    let kept = try await phone.open(.draft(id: try #require(UUID(uuidString: row.id))))
    #expect(phone.onScreen == "Mine")
    await kept.publish()
    await phone.leave(kept)
    await phone.leaveApp()
    await phone.returnToApp()
    #expect(phone.publishes.isEmpty)
    #expect(phone.github.gists.isEmpty)
    try await phone.delete(row: row.id)
    #expect(phone.rows.isEmpty)
  }

  // MARK: Deleting

  @Test func deletingAGistRemovesItFromGitHubAndClosesIt() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("One, typed", in: a)
    try await phone.delete(row: "a")
    #expect(phone.github.requests.filter { $0.hasPrefix("DELETE") } == ["DELETE /gists/a"])
    #expect(phone.github.gists.map(\.id) == ["b"])
    #expect(phone.rows.map(\.id) == ["b"])
    #expect(phone.onScreen == nil)
    phone.goOffline()
    await phone.relaunch()
    #expect(phone.rows.map(\.id) == ["b"])
    #expect(phone.onScreen == nil)
  }

  @Test func deletingANewGistOfflineRemovesIt() async throws {
    let phone = try await Phone()
    await phone.launch()
    phone.goOffline()
    let new = try await phone.open(.new)
    try await phone.type("# Draft\n\nNever published", in: new)
    try await phone.delete(row: try #require(phone.rows.first).id)
    #expect(phone.onScreen == nil)
    #expect(phone.rows.isEmpty)
    phone.goOnline()
    await phone.returnToApp()
    #expect(phone.publishes.isEmpty)
  }

  @Test func deletingADailyNoteRemovesItsDayOrTheGistWithItsLastDay() async throws {
    let phone = try await Phone {
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: ["2026-10-23.md": "The alpha day", "2026-10-24.md": "The beta day"])
    }
    await phone.launch()
    try await phone.delete(row: "d/2026-10-24.md")
    #expect(phone.days == ["d/2026-10-23.md"])
    #expect(phone.onGitHub("d", "2026-10-24.md") == nil)
    #expect(phone.onGitHub("d", "2026-10-23.md") == "The alpha day")
    try await phone.delete(row: "d/2026-10-23.md")
    #expect(phone.github.gists.isEmpty)
    #expect(phone.days.isEmpty)
  }

  @Test func deletingTodayClosesItUntilYouOpenItAgain() async throws {
    let today = DailyNote.Day().filename
    let phone = try await Phone {
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: [today: "Today's words", "2020-01-01.md": "An earlier day"])
    }
    await phone.launch()
    try await phone.open(.today())
    try await phone.delete(row: "d/\(today)")
    #expect(phone.onScreen == nil)
    #expect(phone.onGitHub("d", today) == nil)
    await phone.returnToApp()
    #expect(phone.days == ["d/2020-01-01.md"])
    try await phone.open(.today())
    #expect(phone.onScreen == "# \(today.dropLast(3))\n\n")
  }

  // MARK: Changing a gist

  @Test func renamingStarringAndPinningNeedAConnection() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    phone.goOffline()
    let changes: [Change] = [
      .rename(gistID: "a", title: "Renamed"), .star(gistID: "a", starred: true),
      .preferences([.setPinned(gistID: "a", pinned: true)]),
    ]
    for change in changes {
      await #expect(throws: (any Error).self) {
        _ = try await phone.library.apply(change, accountID: phone.accountID)
      }
    }
    phone.goOnline()
    await phone.returnToApp()
    #expect(phone.github.gists.first?.description == "First")
    #expect(phone.rows.first?.isStarred == false)
    #expect(phone.rows.first?.isPinned == false)
  }

  @Test func renamingAFileKeepsWhatYouTyped() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("Mine", in: a)
    _ = try await phone.library.apply(
      .renameFile(gistID: "a", filename: "README.md", newFilename: "Notes.md"),
      accountID: phone.accountID)
    #expect(a.editor.text == "Mine")
    await phone.leave(a)
    #expect(phone.onGitHub("a", "Notes.md") == "Mine")
    #expect(phone.onGitHub("a", "README.md") == nil)
  }

  @Test func someoneElsesGistIsReadOnly() async throws {
    let phone = try await Phone {
      $0.addGist(
        id: "shared", description: "Theirs", files: ["README.md": "Theirs"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    await phone.launch()
    let shared = try await phone.open(.gist(id: "shared"))
    #expect(!shared.details.access.canEdit)
    #expect(!shared.editor.textView.isEditable)
    #expect(phone.library.deletion(forRow: "shared") == nil)
  }

  // MARK: Accounts

  @Test func signingOutAndBackInKeepsWhatYouTyped() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    let mine = "Mine e\u{301} 日本語 👩🏽‍💻"
    phone.goOffline()
    try await phone.type(mine, in: a)
    await phone.leave(a)
    phone.goOnline()
    _ = try await phone.library.apply(.signOut, accountID: phone.accountID)
    #expect(phone.library.account == nil)
    #expect(phone.library.state.loadState == .signedOut)
    #expect(phone.library.state.gists.isEmpty)
    #expect(phone.onScreen == nil)
    await phone.library.signIn()
    #expect(phone.library.account?.id == phone.accountID)
    await phone.returnToApp()
    #expect(phone.onGitHub("a")?.utf8.elementsEqual(mine.utf8) == true)
  }

  @Test func keepingYourAccountWhenAnotherSignsInHoldsEditsUntilYouReconnect() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("Mine", in: a)
    let other = UUID()
    try phone.fixture.signInNext(as: other, login: FixtureServer.someoneElse.login)
    await phone.library.signIn()
    #expect(phone.library.account?.id == phone.accountID)
    #expect(phone.library.pendingAccount?.id == other)
    phone.library.keepCurrentAccount()
    #expect(phone.library.pendingAccount == nil)
    await phone.leave(a)
    #expect(phone.onGitHub("a") == "One")
    guard case .reconnectRequired = phone.library.state.loadState else {
      Issue.record("Expected a prompt to reconnect")
      return
    }
  }

  // MARK: Daily notes

  @Test func aTodayActionFocusesTheEditorOncePerRequest() async throws {
    let fixture = try await LibraryFixture()
    let library = fixture.library
    await library.start()
    await library.open(.today())
    let file = try #require(library.loadedFile)
    let draft = file.draft
    #expect(file.editingRequestID != nil)
    let session = FileSession(file: file, library: library)
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
    let typed = try await library.save(today, text: "- [ ] One task", generation: 1)
    _ = try await library.publish(typed)
    await library.open(.gist(id: "a"))
    await library.open(.today())
    #expect(library.loadedFile?.draft.text == typed.text)
    #expect(library.loadedFile?.gist?.isDailyNote == true)
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
    #expect(library.loadedFile?.draft.filename == target.filename)
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
    let typed = try await library.save(draft, text: text, generation: draft.generation + 1)
    let row = try #require(library.state.gists.first { $0.id == rowID })
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(row.isOverdue)
    _ = try await library.publish(typed)
    #expect(fixture.remote("daily", "2026-10-24.md") == text)
    #expect(fixture.publishes == ["PATCH /gists/daily"])
    #expect(library.loadedFile?.id == fileID)
    #expect(library.state.selectedID == rowID)
    #expect(library.state.dailyNoteCount == 3)
    #expect(library.state.gists.filter { $0.id == rowID }.count == 1)
    #expect(!library.state.gists.contains { $0.id == draft.id.uuidString })
  }

  /// A day started on the web shows its tasks with nothing open. Refresh reads today's file only
  /// when the Daily notes gist changed, and a failed read shows nothing.
  @Test func refreshReadsTodayWhenTheDailyGistChanges() async throws {
    let today = DailyNote.filename()
    let fixture = try await LibraryFixture {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [today: "- [x] One\n- [ ] Two"], updatedAt: .now - 60)
    }
    let raw = "GET /\(FixtureServer.you.login)/daily/raw/\(today)"
    let reads = { fixture.server.requests.filter { $0 == raw }.count }
    let library = fixture.library
    fixture.fail(raw)
    await library.start()
    #expect(library.remoteRefreshStatus == .idle)
    #expect(library.state.today.text == nil)
    fixture.restore()
    await library.refresh()
    #expect(library.loadedFile == nil)
    #expect(library.state.today.progress == .init(completed: 1, total: 2))
    await library.refresh()
    #expect(reads() == 1)
    fixture.server.edit("daily", files: [today: "- [x] One\n- [x] Two"])
    await library.refresh()
    #expect(reads() == 2)
    #expect(library.state.today.progress == .init(completed: 2, total: 2))
    let row = library.state.unfilteredGists(in: .dailyNotes).first { $0.id == "daily/\(today)" }
    #expect(row?.progress == .init(completed: 2, total: 2))
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
    #expect(library.loadedFile?.draft.text == "The beta day")
    #expect(library.state.selectedID == "daily/2026-10-24.md")
    await library.openRow(id: "daily/2026-10-23.md")
    #expect(library.loadedFile?.draft.text == "The alpha day")
    #expect(library.state.selectedID == "daily/2026-10-23.md")
    await library.open(.gist(id: "daily", filename: "2026-10-24.md"))
    #expect(library.state.selectedID == "daily/2026-10-24.md")
    #expect(library.loadedFile?.rowID == "daily/2026-10-24.md")
    #expect(
      library.deletion(forRow: "daily/2026-10-24.md")
        == .deleteFile(gistID: "daily", filename: "2026-10-24.md"),
      "A Daily row deletes only its own file.")
  }

  @Test func aDayThatPublishesWhileItsDeletionWaitsRemovesOnlyThatDay() async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
    }
    let accountID = fixture.account.id
    // An earlier day written offline, before there was a daily notes gist.
    let earlier = try await fixture.store.save(
      Draft(
        accountID: accountID, githubUserID: FixtureServer.you.id, filename: "2026-10-23.md",
        description: DailyNote.gistDescription),
      text: "The alpha day", generation: 1)
    let library = fixture.library
    await library.start()
    // Its deletion is confirmed, then it publishes and Today joins the gist it creates.
    await library.publishDrafts()
    let gistID = try #require(fixture.server.gists.first(where: \.isDailyNote)?.id)
    await library.open(.today())
    let today = try #require(library.loadedFile?.draft)
    #expect(today.gistID == gistID)
    let typed = try await library.save(
      today, text: "- [ ] Today's task", generation: today.generation + 1)
    _ = try await library.publish(typed)
    #expect(fixture.remote(gistID, "2026-10-23.md") == "The alpha day")

    let settled = try await library.settledDeletionAction(
      .discardLocalCopy(earlier),
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
          // WebKit's content process can take several seconds to start while the suite runs.
          let deadline = ContinuousClock.now.advanced(by: .seconds(15))
          while !rendered, ContinuousClock.now < deadline {
            rendered = try await preview.callAsyncJavaScript(
              "return document.body.innerText.includes('retained');",
              arguments: [:], in: nil, contentWorld: .page) as? Bool == true
            if !rendered { try await Task.sleep(for: .milliseconds(100)) }
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

  @Test func leavingANewBlankNoteLeavesNothingBehind() async throws {
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
        && host.library.sessions[first.id] == nil
    }
    #expect(host.library.state.selectedID == "kept")

    await host.library.open(.new)
    let second = try #require(host.library.visibleFile?.draft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    host.returnToLibrary()
    try await host.waitUntil { host.isLibraryVisible && host.library.loadedFile == nil }
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
    let typed = ContinuousClock.now
    editor.insertText("Local ")
    try await host.waitUntil {
      host.library.localDrafts.first { $0.gistID == "a" }?.generation == 1
    }
    host.returnToLibrary()
    try await host.waitUntil { fixture.remote("a", "README.md") == "Local Current source" }
    // Autosave waits five quiet seconds after typing, so a publish before then came from leaving.
    if autosave { #expect(ContinuousClock.now - typed < .seconds(5)) }
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
    #expect(!host.library.localDrafts.contains { $0.id == draft.id })
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
    sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        Attachment.record(
          """
          load: \(library.state.loadState)
          selected: \(String(describing: library.state.selectedID))
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
        Issue.record(
          "The mounted library did not reach its expected presentation.",
          sourceLocation: sourceLocation)
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
