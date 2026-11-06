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
    fixture.library.isForeground = true
    #expect(session.updateAutosave() == nil)
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
  private func makeFixture() async throws -> LibraryFixture {
    try await LibraryFixture {
      $0.addGist(id: "a", description: "Session fixture", files: ["README.md": "Base"])
    }
  }

  private func edit(_ session: FileSession, to text: String) {
    session.editor.textView.text = text
    session.editor.textViewDidChange(session.editor.textView)
  }
}

private extension LibraryFixture {
  /// Opens gist "a" as the app does, in an editor that autosaves after a short pause.
  func open() async throws -> FileSession {
    if library.account == nil { await library.start() }
    await library.open(.gist(id: "a"))
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
