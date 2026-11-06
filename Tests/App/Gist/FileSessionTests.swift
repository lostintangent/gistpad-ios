import Foundation
import Editor
import Interface
import Testing
import UIKit

@testable import GistPad
@testable import Sync

@Suite(.serialized)
@MainActor
struct FileSessionTests {
  @Test func autosavePublishesOnlyADurableQuietForegroundGeneration() async throws {
    let fixture = try await makeFixture()
    let session = try await fixture.open()
    edit(session, to: "First draft")
    #expect(session.autosave(foreground: true) == nil, "Not before it's saved on this iPhone.")
    #expect(await session.waitForLocalSave())
    #expect(session.autosave(foreground: false) == nil)
    session.editor.textViewWritingToolsWillBegin(session.editor.textView)
    #expect(session.autosave(foreground: true) == nil)
    session.editor.textViewWritingToolsDidEnd(session.editor.textView)
    let older = try #require(session.autosave(foreground: true))
    edit(session, to: "Latest draft")
    let latest = try #require(session.autosave(foreground: true))
    await older.value
    await latest.value
    #expect(fixture.publishes == ["PATCH /gists/a"])
    #expect(fixture.remote("a", "README.md") == "Latest draft")
    #expect(session.saveState == .savedToGitHub)
  }

  @Test(arguments: [true, false])
  func leavingTheAppPublishesEveryOpenFileWithAutosaveOnOrOff(autosave: Bool) async throws {
    let fixture = try await makeFixture(autosave: autosave)
    fixture.server.addGist(id: "b", description: "Another file", files: ["README.md": "Base"])
    let first = try await fixture.open(.gist(id: "a"))
    let second = try await fixture.open(.gist(id: "b"))
    edit(first, to: "Typed before saving")
    edit(second, to: "Typed in another file")
    #expect(await first.waitForLocalSave())
    #expect(await second.waitForLocalSave())
    // Leaving the foreground cancels a pending autosave. Only leaving the app publishes.
    let timer = first.autosave(foreground: true)
    #expect((timer != nil) == autosave)
    #expect(first.autosave(foreground: false) == nil)
    await timer?.value
    #expect(fixture.publishes.isEmpty)

    let gate = fixture.hold("PATCH /gists/a")
    let saving = Task { await first.publish() }
    try await gate.arrival()
    edit(first, to: "Typed while that save was sending")
    #expect(await first.waitForLocalSave())
    let leaving = Task {
      await FileSession.publishOnBackground([first, second], shouldContinue: { true })
    }
    await Task.yield()
    gate.open()
    await saving.value
    await leaving.value
    #expect(fixture.publishes.filter { $0 == "PATCH /gists/a" }.count == 2)
    #expect(fixture.remote("a", "README.md") == "Typed while that save was sending")
    #expect(fixture.remote("b", "README.md") == "Typed in another file")
    #expect(first.saveState == .savedToGitHub)
    #expect(second.saveState == .savedToGitHub)
  }

  enum Moment: CaseIterable { case typing, leavingTheNote, leavingTheApp, returningToTheApp }

  @Test(arguments: Moment.allCases)
  func todayOpenedOfflinePublishesAtTheNextMomentOnceOnline(_ moment: Moment) async throws {
    let fixture = try await LibraryFixture(
      selection: .init(gistID: "a", filename: "README.md", draftID: nil)
    ) {
      $0.addGist(id: "a", description: "Session fixture", files: ["README.md": "Base"])
    }
    let library = fixture.library
    await library.start()
    fixture.fail()
    await library.open(.today())
    let today = try #require(library.loadedFile?.draft)
    #expect(today.filename == DailyNote.Day().filename)
    let session = try #require(library.sessions[today.id])
    edit(session, to: today.text + "- [ ] Walk")
    #expect(await session.waitForLocalSave())
    // Today's create goes out and is cut off, so GitHub may or may not have it.
    await library.publishUnsyncedEdits()
    #expect(session.saveState == .failed(.network))
    #expect(try await fixture.saved(session).attemptedContent == session.editor.text)

    fixture.restore()
    switch moment {
    case .typing:
      edit(session, to: session.editor.text + " the dog")
      #expect(await session.waitForLocalSave())
      #expect(session.saveState == .savedLocally)
      library.isForeground = true
      #expect(session.autosaveRequest.eligible)
      await session.publish(reason: .autosave)
    case .leavingTheNote: await session.leave()
    case .leavingTheApp: await FileSession.publishOnBackground([session], shouldContinue: { true })
    case .returningToTheApp: await library.publishUnsyncedEdits()
    }
    #expect(fixture.publishes == ["POST /gists"])
    let daily = try #require(fixture.server.gists.first { $0.isDailyNote })
    #expect(fixture.remote(daily.id, today.filename) == session.editor.text)
    #expect(session.saveState == .savedToGitHub)
    #expect(session.file.gist?.id == daily.id)
  }

  @Test func restoredGenerationsAndRapidEditsPersistInOrder() async throws {
    let fixture = try await makeFixture()
    let restored = try await fixture.stageEdit(
      gistID: "a", filename: "README.md", text: "Restored local draft")
    let session = try await fixture.open()
    #expect(session.editor.text == "Restored local draft")
    #expect(session.editor.generation == restored.generation)
    for text in ["First", "Second", "日本語 👨‍👩‍👧‍👦"] { edit(session, to: text) }
    #expect(await session.waitForLocalSave())
    let saved = try await fixture.saved(session)
    #expect(saved.generation == restored.generation + 3)
    #expect(saved.text.utf8.elementsEqual("日本語 👨‍👩‍👧‍👦".utf8))
    #expect(session.saveState == .savedLocally)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aPublishResponseCannotReplaceNewerTyping() async throws {
    let fixture = try await makeFixture()
    let session = try await fixture.open()
    edit(session, to: "The manually saved generation")
    #expect(await session.waitForLocalSave())
    let gate = fixture.hold("PATCH /gists/a")
    let publishing = Task { await session.publish() }
    try await gate.arrival()
    edit(session, to: "Newer typing stays local")
    #expect(await session.waitForLocalSave())
    gate.open()
    await publishing.value
    #expect(fixture.remote("a", "README.md") == "The manually saved generation")
    #expect(session.editor.text == "Newer typing stays local")
    #expect(session.draft.text == "Newer typing stays local")
    #expect(session.draft.baseContent == "The manually saved generation")
    #expect(session.saveState == .savedLocally)
  }

  @Test func writingToolsPersistsOnlyTheFinalChoiceAndNeverPublishesPreviews() async throws {
    let fixture = try await makeFixture()
    let session = try await fixture.open()
    let editor = session.editor.textView
    let accepted = "The accepted rewrite 日本語 👩🏽‍💻"
    session.editor.textViewWritingToolsWillBegin(editor)
    edit(session, to: "Temporary rewrite")
    #expect(session.editor.text == "Base")
    await session.publish()
    edit(session, to: accepted)
    session.editor.textViewWritingToolsDidEnd(editor)
    #expect(await session.waitForLocalSave())
    #expect(try await fixture.saved(session).generation == 1)
    #expect(try await fixture.saved(session).text == accepted)

    session.editor.textViewWritingToolsWillBegin(editor)
    edit(session, to: "A rejected rewrite")
    edit(session, to: accepted)
    session.editor.textViewWritingToolsDidEnd(editor)
    #expect(await session.waitForLocalSave())
    #expect(try await fixture.saved(session).generation == 1)
    #expect(session.saveState == .savedLocally)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func anEditFromAShortcutIsOneUndo() async throws {
    let fixture = try await makeFixture()
    let session = try await fixture.open()
    let window = try EditorContinuityTests().host(session.editor)
    defer { window.isHidden = true }
    let image = "\n![Image](https://example.test/image.png)"
    let insertion = DraftEdit(
      draftID: session.draft.id, accountID: fixture.account.id,
      expectedGeneration: session.editor.generation, text: image)
    try await session.applyDurableEdit(insertion) { try await fixture.store.apply(insertion) }
    #expect(session.editor.text == "Base" + image)
    session.editor.textView.undoManager?.undo()
    #expect(session.editor.text == "Base")

    edit(session, to: "Newer 日本語")
    #expect(await session.waitForLocalSave())
    await #expect(throws: DraftError.staleGeneration) {
      try await session.applyDurableEdit(insertion) { try await fixture.store.apply(insertion) }
    }
    #expect(session.editor.text == "Newer 日本語")
    #expect(try await fixture.saved(session).text == "Newer 日本語")
    #expect(fixture.publishes.isEmpty)
  }

  @Test func recoveryEditsStayLocalAndCannotRecreateADeletedGist() async throws {
    let fixture = try await LibraryFixture()
    let staged = try await fixture.stageEdit(gistID: "gone", filename: "README.md", text: "Kept")
    let session = try await fixture.open(.draft(id: staged.id))
    #expect(session.file.isRecovery)
    edit(session, to: "A recoverable local edit")
    #expect(await session.waitForLocalSave())
    #expect(!session.saveState.canPublish)
    await session.publish()
    await FileSession.publishOnBackground([session], shouldContinue: { true })
    await fixture.library.publishUnsyncedEdits()
    #expect(fixture.publishes.isEmpty)
    #expect(try await fixture.saved(session).text == "A recoverable local edit")
  }

  @Test func retainedRemoteChangeIsReviewedWithoutReplacingSourceSelectionOrUndo() async throws {
    let fixture = try await makeFixture()
    let session = try await fixture.open()
    let window = try EditorContinuityTests().host(session.editor)
    defer { window.isHidden = true }
    let editor = session.editor.textView
    editor.becomeFirstResponder()
    editor.selectedRange = NSRange(location: 4, length: 0)
    editor.insertText(", kept here")
    editor.selectedRange = NSRange(location: 4, length: 3)
    #expect(await session.waitForLocalSave())
    fixture.server.edit("a", files: ["README.md": "Changed in the web app"])
    await session.inspectRemoteChanges()
    #expect(session.editor.text == "Base, kept here")
    #expect(editor.selectedRange == NSRange(location: 4, length: 3))
    #expect(session.saveState.isConflict)
    #expect(try session.reviewContext().conflict.remote == "Changed in the web app")
    #expect(session.autosave(foreground: true) == nil)
    editor.undoManager?.undo()
    #expect(session.editor.text == "Base")
    #expect(await session.waitForLocalSave())
    #expect(session.saveState.isConflict)
    #expect(fixture.publishes.isEmpty)
  }

  /// Opening a note shows the phone's copy, then GitHub's newer text, as RootView reads it when the
  /// note appears. Opening it again within five minutes reads nothing.
  @Test func openingANoteShowsGitHubsNewerTextAndReopeningItSoonReadsNothing() async throws {
    let fixture = try await LibraryFixture {
      $0.addGist(id: "a", description: "A", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "B", files: ["README.md": "Two"])
    }
    await fixture.library.start()
    await fixture.library.open(.gist(id: "a"))
    fixture.server.edit("a", files: ["README.md": "Changed on the web"])
    let library = fixture.relaunch()
    await library.start()
    let note = try #require(library.activeSession)
    #expect(note.editor.text == "One")
    await note.inspectRemoteChanges()
    #expect(note.editor.text == "Changed on the web")
    let reads = fixture.server.requests.filter { $0 == "GET /gists/a" }.count
    fixture.server.edit("a", files: ["README.md": "Changed again"])
    await library.open(.gist(id: "b"))
    await library.activeSession?.inspectRemoteChanges()
    await library.open(.gist(id: "a"))
    #expect(library.activeSession === note)
    await note.inspectRemoteChanges()
    #expect(note.editor.text == "Changed on the web")
    #expect(fixture.server.requests.filter { $0 == "GET /gists/a" }.count == reads)
    #expect(fixture.publishes.isEmpty)
  }

  @Test(arguments: [true, false])
  func resolvingAConflictEitherWayKeepsUndoHonest(keepsMine: Bool) async throws {
    let fixture = try await makeFixture()
    let session = try await fixture.open()
    let window = try EditorContinuityTests().host(session.editor)
    defer { window.isHidden = true }
    edit(session, to: "Mine")
    #expect(await session.waitForLocalSave())
    fixture.server.edit("a", files: ["README.md": "From GitHub 日本語"])
    await session.inspectRemoteChanges()
    let undo = try #require(session.editor.textView.undoManager)
    undo.removeAllActions()
    let generation = session.editor.generation
    let choice = keepsMine ? "Mine" : "From GitHub 日本語"
    try await session.applyReview(session.reviewContext(), text: choice, publishes: false)
    #expect(session.editor.text == choice)
    // Keeping my text changes nothing to undo. Taking GitHub's is one undo back to mine.
    #expect(session.editor.generation == generation + (keepsMine ? 0 : 1))
    #expect(undo.canUndo == !keepsMine)
    #expect(session.saveState == (keepsMine ? .savedLocally : .savedToGitHub))
    #expect(fixture.publishes.isEmpty)
    guard !keepsMine else { return }
    undo.undo()
    #expect(session.editor.text == "Mine")
    #expect(await session.waitForLocalSave())
    #expect(try await fixture.saved(session).text == "Mine")
  }

  /// A signed-in library whose GitHub has one published file: gist "a", README.md, "Base".
  private func makeFixture(autosave: Bool = true) async throws -> LibraryFixture {
    try await LibraryFixture(autosave: autosave) {
      $0.addGist(id: "a", description: "Session fixture", files: ["README.md": "Base"])
    }
  }

  private func edit(_ session: FileSession, to text: String) {
    session.editor.textView.text = text
    session.editor.textViewDidChange(session.editor.textView)
  }
}

extension FileSession {
  /// Moves the app in or out of the foreground, then schedules autosave as the app would.
  @discardableResult
  func autosave(foreground: Bool) -> Task<Void, Never>? {
    library.isForeground = foreground
    return updateAutosave()
  }
}

private extension LibraryFixture {
  /// Opens a file as the app does, in an editor that autosaves after a short pause.
  func open(
    _ request: Opening.Request = .gist(id: "a")
  ) async throws -> FileSession {
    if library.account == nil { await library.start() }
    await library.open(request)
    let file = try #require(library.loadedFile)
    let draft = try #require(file.draft)
    return FileSession(
      file: file, draft: draft, library: library, autosaveDelay: .milliseconds(30))
  }

  /// The editor's file as it's saved on this iPhone.
  func saved(_ session: FileSession) async throws -> Draft {
    try await store.draft(id: session.draft.id, accountID: account.id)
  }
}

extension PublishState {
  fileprivate var isConflict: Bool {
    if case .conflict = self { true } else { false }
  }
}
