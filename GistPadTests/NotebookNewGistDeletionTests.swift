import Foundation
import Testing

@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct NotebookNewGistDeletionTests {
  @Test(arguments: [false, true])
  func automaticPublicationMakesTheNewGistDeletableWithoutAnotherRead(leaving: Bool) async throws {
    let provider = LibraryDeletionCaptureProvider(autosave: true)
    let notebook = NotebookModel(provider: provider)
    await notebook.start()
    #expect(notebook.library.loadState == .ready)
    let listReads = await provider.libraryReadCount
    let metadataReads = await provider.metadataReadCount
    await notebook.createNote()
    let document = try #require(notebook.loadedDocument)
    let draft = try #require(document.draft)
    let controller = NotebookSessionController(
      document: document, draft: draft, notebook: notebook,
      autosaveDelay: leaving ? .seconds(60) : .milliseconds(10))
    controller.session.textView.text = "A thought published without pressing Save"
    controller.session.textViewDidChange(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    let timer = try #require(controller.updateAutosave(isForeground: true))
    if leaving {
      notebook.showLibrary()
      #expect(!(await controller.finishLeavingNote()))
      #expect(timer.isCancelled)
    }
    await timer.value
    let saved = try #require(notebook.localDrafts.first { $0.id == draft.id })
    #expect(saved.state == .savedToGitHub)
    #expect(controller.saveState == .savedToGitHub)
    #expect(!controller.isPublishing)
    let gistID = try #require(saved.gistID)
    #expect(controller.document.gist?.id == gistID)
    let row = try #require(notebook.library.snapshot.notes.first { $0.id == gistID })
    #expect(row.canDeleteFromGitHub)
    #expect(row.isOwned)
    #expect(!row.isRecovery)
    #expect(notebook.library.snapshot.notes.allSatisfy { $0.id != draft.id.uuidString })
    #expect(notebook.libraryDeletionTarget(for: draft.id.uuidString)?.id == gistID)
    let target = try #require(notebook.libraryDeletionTarget(for: row.id))
    #expect(target.localDraft == nil)
    #expect(target.id == gistID)
    #expect(await provider.publicationReasons == [leaving ? PublishReason.leaving : .autosave])
    #expect(await provider.libraryReadCount == listReads)
    #expect(await provider.metadataReadCount == metadataReads)
    try controller.beginDestructiveAction()
    defer { controller.endDestructiveAction() }
    _ = try await notebook.perform(target.action)
    #expect(notebook.library.snapshot.notes.allSatisfy { $0.gistID != gistID })
    #expect(notebook.localDrafts.allSatisfy { $0.id != draft.id })
    #expect(await provider.libraryReadCount == listReads)
  }
}
