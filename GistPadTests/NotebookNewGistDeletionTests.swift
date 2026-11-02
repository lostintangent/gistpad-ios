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

  @Test
  func deletingANewNoteWhileItPublishesLeavesNothingOnGitHubOrTheDevice() async throws {
    let provider = LibraryDeletionCaptureProvider(autosave: false)
    let notebook = NotebookModel(provider: provider)
    await notebook.start()
    #expect(notebook.library.loadState == .ready)
    await notebook.createNote()
    let accountID = try #require(notebook.account?.id)
    let document = try #require(notebook.loadedDocument)
    let draft = try #require(document.draft)
    let controller = NotebookSessionController(
      document: document, draft: draft, notebook: notebook, autosaveDelay: .seconds(60))
    controller.session.textView.text = "Deleted while it publishes"
    controller.session.textViewDidChange(controller.session.textView)
    #expect(await controller.waitForLocalSave())

    let hold = LibraryPublicationHold.shared
    hold.enable()
    defer { hold.release() }
    let publication = Task { await controller.publish() }
    #expect(await hold.waitUntilParked())
    #expect(controller.isPublishing)

    let target = try #require(notebook.libraryDeletionTarget(for: draft.id.uuidString))
    #expect(target.isUncertainCreation)
    let action = target.action
    let confirmedWithoutGist = notebook.localDrafts.first { $0.id == draft.id }?.gistID == nil
    #expect(confirmedWithoutGist)

    let deletion = Task { () throws -> NotebookActionResult in
      await controller.waitForPublication()
      try controller.beginDestructiveAction()
      defer { controller.endDestructiveAction() }
      guard await controller.waitForLocalSave() else {
        throw NotebookEditError.localPersistenceFailed
      }
      let settled = try await notebook.settledDeletionAction(
        action, confirmedWithoutGist: confirmedWithoutGist, accountID: accountID)
      return try await notebook.perform(settled)
    }
    // Lets the delete reach its publication wait. The assertions hold whichever order the tasks run in.
    try await Task.sleep(for: .milliseconds(20))
    hold.release()
    await publication.value
    let result = try await deletion.value

    guard case .deleted(let deletedID) = result else {
      Issue.record("Expected the new gist to be deleted, got \(result)")
      return
    }
    #expect(deletedID == "newcapture")
    #expect(notebook.deletedGistIDs.contains("newcapture"))
    #expect(notebook.localDrafts.allSatisfy { $0.id != draft.id })
    #expect(!controller.isPublishing)
    let remaining = try await provider.gists(accountID: accountID)
    #expect(!remaining.contains { $0.id == "newcapture" })
  }
}
