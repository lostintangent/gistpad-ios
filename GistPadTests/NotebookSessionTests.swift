import Foundation
import GistPadEditor
import GistPadInterface
import Testing
import UIKit

@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct NotebookSessionTests {
  @Test func autosavePublishesOnlyADurableQuietForegroundGeneration() async throws {
    let fixture = try await makeFixture()
    let controller = try await fixture.open()
    edit(controller, to: "First draft")
    #expect(controller.autosave(foreground: true) == nil, "Not before it's saved on this iPhone.")
    #expect(await controller.waitForLocalSave())
    #expect(controller.autosave(foreground: false) == nil)
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    #expect(controller.autosave(foreground: true) == nil)
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    let older = try #require(controller.autosave(foreground: true))
    edit(controller, to: "Latest draft")
    let latest = try #require(controller.autosave(foreground: true))
    await older.value
    await latest.value
    #expect(fixture.publishes == ["PATCH /gists/a"])
    #expect(fixture.remote("a", "README.md") == "Latest draft")
    #expect(controller.saveState == .savedToGitHub)
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
      await NotebookLifecycle.saveOnBackground([first, second], shouldContinue: { true })
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

  @Test func restoredGenerationsAndRapidEditsPersistInOrder() async throws {
    let fixture = try await makeFixture()
    let restored = try await fixture.stageEdit(
      gistID: "a", filename: "README.md", text: "Restored local draft")
    let controller = try await fixture.open()
    #expect(controller.session.text == "Restored local draft")
    #expect(controller.session.generation == restored.generation)
    for text in ["First", "Second", "日本語 👨‍👩‍👧‍👦"] { edit(controller, to: text) }
    #expect(await controller.waitForLocalSave())
    let saved = try await fixture.saved(controller)
    #expect(saved.generation == restored.generation + 3)
    #expect(saved.text.utf8.elementsEqual("日本語 👨‍👩‍👧‍👦".utf8))
    #expect(controller.saveState == .savedLocally)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aPublishResponseCannotReplaceNewerTyping() async throws {
    let fixture = try await makeFixture()
    let controller = try await fixture.open()
    edit(controller, to: "The manually saved generation")
    #expect(await controller.waitForLocalSave())
    let gate = fixture.hold("PATCH /gists/a")
    let publishing = Task { await controller.publish() }
    try await gate.arrival()
    edit(controller, to: "Newer typing stays local")
    #expect(await controller.waitForLocalSave())
    gate.open()
    await publishing.value
    #expect(fixture.remote("a", "README.md") == "The manually saved generation")
    #expect(controller.session.text == "Newer typing stays local")
    #expect(controller.draft.text == "Newer typing stays local")
    #expect(controller.draft.baseContent == "The manually saved generation")
    #expect(controller.saveState == .savedLocally)
  }

  @Test func writingToolsPersistsOnlyTheFinalChoiceAndNeverPublishesPreviews() async throws {
    let fixture = try await makeFixture()
    let controller = try await fixture.open()
    let editor = controller.session.textView
    let accepted = "The accepted rewrite 日本語 👩🏽‍💻"
    controller.session.textViewWritingToolsWillBegin(editor)
    edit(controller, to: "Temporary rewrite")
    #expect(controller.session.text == "Base")
    await controller.publish()
    edit(controller, to: accepted)
    controller.session.textViewWritingToolsDidEnd(editor)
    #expect(await controller.waitForLocalSave())
    #expect(try await fixture.saved(controller).generation == 1)
    #expect(try await fixture.saved(controller).text == accepted)

    controller.session.textViewWritingToolsWillBegin(editor)
    edit(controller, to: "A rejected rewrite")
    edit(controller, to: accepted)
    controller.session.textViewWritingToolsDidEnd(editor)
    #expect(await controller.waitForLocalSave())
    #expect(try await fixture.saved(controller).generation == 1)
    #expect(controller.saveState == .savedLocally)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func anEditFromAShortcutIsOneUndo() async throws {
    let fixture = try await makeFixture()
    let controller = try await fixture.open()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let image = "\n![Image](https://example.test/image.png)"
    let insertion = DraftEdit(
      draftID: controller.draft.id, accountID: fixture.account.id,
      expectedGeneration: controller.session.generation, range: NSRange(location: 4, length: 0),
      expectedText: "", replacement: image)
    try await controller.applyDurableEdit(insertion) { try await fixture.store.apply(insertion) }
    #expect(controller.session.text == "Base" + image)
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == "Base")

    edit(controller, to: "Newer 日本語")
    #expect(await controller.waitForLocalSave())
    await #expect(throws: DraftError.staleGeneration) {
      try await controller.applyDurableEdit(insertion) { try await fixture.store.apply(insertion) }
    }
    #expect(controller.session.text == "Newer 日本語")
    #expect(try await fixture.saved(controller).text == "Newer 日本語")
    #expect(fixture.publishes.isEmpty)
  }

  @Test func recoveryEditsStayLocalAndCannotRecreateADeletedGist() async throws {
    let fixture = try await NotebookFixture()
    let staged = try await fixture.stageEdit(gistID: "gone", filename: "README.md", text: "Kept")
    let controller = try await fixture.open(.draft(id: staged.id))
    #expect(controller.document.isRecovery)
    edit(controller, to: "A recoverable local edit")
    #expect(await controller.waitForLocalSave())
    #expect(!controller.saveState.canPublish)
    await controller.publish()
    await NotebookLifecycle.saveOnBackground([controller], shouldContinue: { true })
    await fixture.model.publishUnsyncedEdits()
    #expect(fixture.publishes.isEmpty)
    #expect(try await fixture.saved(controller).text == "A recoverable local edit")
  }

  @Test func retainedRemoteChangeIsReviewedWithoutReplacingSourceSelectionOrUndo() async throws {
    let fixture = try await makeFixture()
    let controller = try await fixture.open()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let editor = controller.session.textView
    editor.becomeFirstResponder()
    editor.selectedRange = NSRange(location: 4, length: 0)
    editor.insertText(", kept here")
    editor.selectedRange = NSRange(location: 4, length: 3)
    #expect(await controller.waitForLocalSave())
    fixture.server.edit("a", files: ["README.md": "Changed in the web app"])
    await controller.inspectRemoteChanges()
    #expect(controller.session.text == "Base, kept here")
    #expect(editor.selectedRange == NSRange(location: 4, length: 3))
    #expect(controller.saveState.isConflict)
    #expect(try controller.reviewContext().conflict.remote == "Changed in the web app")
    #expect(controller.autosave(foreground: true) == nil)
    editor.undoManager?.undo()
    #expect(controller.session.text == "Base")
    #expect(await controller.waitForLocalSave())
    #expect(controller.saveState.isConflict)
    #expect(fixture.publishes.isEmpty)
  }

  @Test(arguments: [true, false])
  func resolvingAConflictEitherWayKeepsUndoHonest(keepsMine: Bool) async throws {
    let fixture = try await makeFixture()
    let controller = try await fixture.open()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    edit(controller, to: "Mine")
    #expect(await controller.waitForLocalSave())
    fixture.server.edit("a", files: ["README.md": "From GitHub 日本語"])
    await controller.inspectRemoteChanges()
    let undo = try #require(controller.session.textView.undoManager)
    undo.removeAllActions()
    let generation = controller.session.generation
    let choice = keepsMine ? "Mine" : "From GitHub 日本語"
    try await controller.applyReview(controller.reviewContext(), text: choice, publishes: false)
    #expect(controller.session.text == choice)
    // Keeping my text changes nothing to undo. Taking GitHub's is one undo back to mine.
    #expect(controller.session.generation == generation + (keepsMine ? 0 : 1))
    #expect(undo.canUndo == !keepsMine)
    #expect(controller.saveState == .savedLocally)
    #expect(fixture.publishes.isEmpty)
    guard !keepsMine else { return }
    undo.undo()
    #expect(controller.session.text == "Mine")
    #expect(await controller.waitForLocalSave())
    #expect(try await fixture.saved(controller).text == "Mine")
  }

  /// A signed-in notebook whose GitHub has one published file: gist "a", README.md, "Base".
  private func makeFixture(autosave: Bool = true) async throws -> NotebookFixture {
    try await NotebookFixture(autosave: autosave) {
      $0.addGist(id: "a", description: "Session fixture", files: ["README.md": "Base"])
    }
  }

  private func edit(_ controller: NotebookSessionController, to text: String) {
    controller.session.textView.text = text
    controller.session.textViewDidChange(controller.session.textView)
  }
}

extension NotebookSessionController {
  /// Moves the app in or out of the foreground, then schedules autosave as the app would.
  @discardableResult
  func autosave(foreground: Bool) -> Task<Void, Never>? {
    notebook.isForeground = foreground
    return updateAutosave()
  }
}

private extension NotebookFixture {
  /// Opens a file as the app does, in an editor that autosaves after a short pause.
  func open(
    _ request: NotebookOpening.Request = .gist(id: "a")
  ) async throws -> NotebookSessionController {
    if model.account == nil { await model.start() }
    await model.open(request)
    let document = try #require(model.loadedDocument)
    let draft = try #require(document.draft)
    return NotebookSessionController(
      document: document, draft: draft, notebook: model, autosaveDelay: .milliseconds(30))
  }

  /// The editor's file as it's saved on this iPhone.
  func saved(_ controller: NotebookSessionController) async throws -> DraftSnapshot {
    try await store.draft(id: controller.draft.id, accountID: account.id)
  }
}

extension PublishState {
  fileprivate var isConflict: Bool {
    if case .conflict = self { true } else { false }
  }
}
