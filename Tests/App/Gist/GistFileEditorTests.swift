import Foundation
@testable import Editor
import Screens
import Testing
import UIKit

@testable import GistPad
@testable import Model
@testable import Store

@Suite(.serialized)
@MainActor
struct GistFileEditorTests {
  @Test func writingToolsPersistsOnlyTheFinalChoiceAndNeverPublishesPreviews() async throws {
    let fixture = try await makeFixture()
    let fileEditor = try await fixture.open()
    let editor = fileEditor.editor.textView
    let accepted = "The accepted rewrite 日本語 👩🏽‍💻"
    fileEditor.editor.textViewWritingToolsWillBegin(editor)
    edit(fileEditor, to: "Temporary rewrite")
    #expect(fileEditor.editor.text == "Base")
    await fileEditor.publish()
    edit(fileEditor, to: accepted)
    fileEditor.editor.textViewWritingToolsDidEnd(editor)
    #expect(await fileEditor.waitForLocalSave())
    #expect(fileEditor.savedGeneration == 1)
    #expect(try await fixture.saved(fileEditor).text == accepted)

    fileEditor.editor.textViewWritingToolsWillBegin(editor)
    edit(fileEditor, to: "A rejected rewrite")
    edit(fileEditor, to: accepted)
    fileEditor.editor.textViewWritingToolsDidEnd(editor)
    #expect(await fileEditor.waitForLocalSave())
    #expect(fileEditor.savedGeneration == 1)
    #expect(fileEditor.status == .unpublished)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func anEditFromAShortcutIsOneUndo() async throws {
    let fixture = try await makeFixture()
    let fileEditor = try await fixture.open()
    let window = try EditorContinuityTests().host(fileEditor.editor)
    defer { window.isHidden = true }
    let image = "\n![Image](https://example.test/image.png)"
    let insertion = DraftEdit(draft: fileEditor.file.nextDraft, text: image)
    try await fileEditor.applyDurableEdit(insertion) { try await fixture.store.apply(insertion, github: nil) }
    #expect(fileEditor.editor.text == "Base" + image)
    fileEditor.editor.textView.undoManager?.undo()
    #expect(fileEditor.editor.text == "Base")

    edit(fileEditor, to: "Newer 日本語")
    #expect(await fileEditor.waitForLocalSave())
    await #expect(throws: DraftError.changed) {
      try await fileEditor.applyDurableEdit(insertion) { try await fixture.store.apply(insertion, github: nil) }
    }
    #expect(fileEditor.editor.text == "Newer 日本語")
    #expect(try await fixture.saved(fileEditor).text == "Newer 日本語")
    #expect(fixture.publishes.isEmpty)
  }

  @Test func retainedRemoteChangeIsReviewedWithoutReplacingSourceSelectionOrUndo() async throws {
    let fixture = try await makeFixture()
    let fileEditor = try await fixture.open()
    let window = try EditorContinuityTests().host(fileEditor.editor)
    defer { window.isHidden = true }
    let editor = fileEditor.editor.textView
    editor.becomeFirstResponder()
    editor.selectedRange = NSRange(location: 4, length: 0)
    editor.insertText(", kept here")
    editor.selectedRange = NSRange(location: 4, length: 3)
    #expect(await fileEditor.waitForLocalSave())
    fixture.server.edit("a", files: ["README.md": "Changed in the web app"])
    await fileEditor.inspectRemoteChanges()
    #expect(fileEditor.editor.text == "Base, kept here")
    #expect(editor.selectedRange == NSRange(location: 4, length: 3))
    #expect(fileEditor.status == .conflict)
    #expect(fileEditor.file.draft?.conflict?.text == "Changed in the web app")
    fixture.model.isForeground = true
    #expect(fileEditor.updateAutosave() == nil)
    editor.undoManager?.undo()
    #expect(fileEditor.editor.text == "Base")
    #expect(await fileEditor.waitForLocalSave())
    #expect(fileEditor.status == .conflict)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func sourceUsesTheSavedFrontMatterPreferenceWithoutChangingTheDraft() async throws {
    let prefix = "---\nedit:\n  instructions: Preserve source bytes\n---\n\n"
    let source = prefix + "# Content\n\nA retained thought."
    let fixture = try await ModelFixture(preferences: [.setBoolean(.showFrontmatter, true)]) {
      $0.addGist(id: "frontmatter", description: "Content", files: ["README.md": source])
    }
    let model = fixture.model
    await model.start()
    await model.open(.gist(id: "frontmatter"))
    let file = try #require(model.loadedFile)
    let fileEditor = GistFileEditor(file: file, model: model)
    let editor = fileEditor.editor
    let generation = editor.generation
    let view = editor.textView
    #expect(editor.showsFrontMatter)
    #expect(editor.contentStart == 0)
    #expect(view.selectedRange == .init(location: 0, length: 0))
    _ = try await fixture.accounts.update(
      [.setBoolean(.showFrontmatter, false)], accountID: fixture.account.id)
    await model.refresh()
    try await fileEditor.refreshMetadata()
    #expect(!editor.showsFrontMatter)
    #expect(editor.contentStart == prefix.utf16.count)
    #expect(editor.textView === view)
    #expect(editor.text.utf8.elementsEqual(source.utf8))
    #expect(editor.generation == generation)
    #expect(view.undoManager?.canUndo != true)
  }

  @Test(arguments: [true, false])
  func resolvingAConflictEitherWayKeepsUndoHonest(keepsMine: Bool) async throws {
    let fixture = try await makeFixture()
    let fileEditor = try await fixture.open()
    let window = try EditorContinuityTests().host(fileEditor.editor)
    defer { window.isHidden = true }
    edit(fileEditor, to: "Mine")
    #expect(await fileEditor.waitForLocalSave())
    fixture.server.edit("a", files: ["README.md": "From GitHub 日本語"])
    await fileEditor.inspectRemoteChanges()
    let undo = try #require(fileEditor.editor.textView.undoManager)
    undo.removeAllActions()
    let generation = fileEditor.editor.generation
    let choice = keepsMine ? "Mine" : "From GitHub 日本語"
    try await fileEditor.resolveConflict(try #require(fileEditor.file.draft), text: choice, publishes: false)
    #expect(fileEditor.editor.text == choice)
    // Keeping my text changes nothing to undo. Taking GitHub's is one undo back to mine.
    #expect(fileEditor.editor.generation == generation + (keepsMine ? 0 : 1))
    #expect(undo.canUndo == !keepsMine)
    #expect(fileEditor.status == (keepsMine ? .unpublished : .published))
    #expect(fixture.publishes.isEmpty)
    guard !keepsMine else { return }
    undo.undo()
    #expect(fileEditor.editor.text == "Mine")
    #expect(await fileEditor.waitForLocalSave())
    #expect(try await fixture.saved(fileEditor).text == "Mine")
  }

  /// A signed-in library whose GitHub has one published file: gist "a", README.md, "Base".
  private func makeFixture() async throws -> ModelFixture {
    try await ModelFixture {
      $0.addGist(id: "a", description: "Session fixture", files: ["README.md": "Base"])
    }
  }

  private func edit(_ fileEditor: GistFileEditor, to text: String) {
    fileEditor.editor.textView.text = text
    fileEditor.editor.textViewDidChange(fileEditor.editor.textView)
  }
}

private extension ModelFixture {
  /// Opens gist "a" as the app does, in an editor that autosaves after a short pause.
  func open() async throws -> GistFileEditor {
    if model.account == nil { await model.start() }
    await model.open(.gist(id: "a"))
    return GistFileEditor(
      file: try #require(model.loadedFile), model: model, autosaveDelay: .milliseconds(30))
  }

  /// The editor's file as it's saved on this iPhone.
  func saved(_ fileEditor: GistFileEditor) async throws -> GistFileDraft {
    try #require(try await store.current(fileEditor.file.nextDraft))
  }
}
