#if DEBUG
import Foundation
import GistPadComments
import GistPadInterface
import Testing
@testable import GistPad

@MainActor
struct NotebookCommentsPresentationTests {
  @Test func hiddenAnnotationsDoNotFetchForTheToolbarCount() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    await presentation.prepareAnnotations(for: controller, showsInline: false)
    #expect(presentation.conversation == nil)
    #expect(await fixture.remote.listRequests == 0)
  }

  @Test func exactSelectionKeepsItsFilenameAcrossAFileSwitchAndNeverChangesSource() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let original = try await open(fixture)
    let originalBytes = Array(original.session.text.utf8)
    let exact = " \tCafé 👩🏽‍💻\r\nsecond **line**  "
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(original)
    presentation.open(for: original, origin: .source, quote: exact)
    let next = try await open(fixture, filename: "Appendix.md")
    presentation.activate(next)
    try await wait {
      guard let target = presentation.conversation?.activeDraft.target,
        case .quote = target else { return false }
      return presentation.conversation?.comments != nil
    }
    let conversation = try #require(presentation.conversation)
    guard case .quote(let quote) = conversation.activeDraft.target else {
      Issue.record("The captured quote was not applied.")
      return
    }
    #expect(quote.filename == "README.md")
    #expect(Array(quote.text.utf8) == Array(exact.utf8))
    #expect(original.mode == .reading)
    #expect(next.mode == .reading)
    conversation.updateText("A deliberate comment")
    await conversation.post()
    #expect(await fixture.remote.createdBodies == [
      GistCommentBody.quoting(exact, text: "A deliberate comment")
    ])
    #expect(Array(original.session.text.utf8) == originalBytes)
    #expect(original.session.generation == 0)
    #expect(next.session.generation == 0)
  }

  @Test func closeRetainsDraftAndReopeningAThreadDoesNotRequestComposerFocus() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    presentation.open(for: controller, origin: .reading, quote: NotebookCommentsCaptureData.passage)
    try await wait { presentation.focusRequest > 0 }
    let conversation = try #require(presentation.conversation)
    conversation.updateText("Keep these words")
    await presentation.close()
    #expect(!presentation.isPresented)
    #expect(presentation.selectedRootID == nil)
    #expect(presentation.focusRequest == 0)
    presentation.didDismiss()
    presentation.open(for: controller, rootID: 300)
    try await wait { presentation.selectedRootID == 300 }
    #expect(presentation.focusRequest == 0)
    #expect(presentation.conversation?.activeDraft.text == "Keep these words")
    #expect(await fixture.remote.createdBodies.isEmpty)
    await presentation.close()
  }

  @Test func failedDraftWritesPreventCloseUntilAnExplicitRetrySucceeds() async throws {
    let fixture = NotebookCommentsCaptureFixture(scenario: "draft-failure")
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    presentation.open(for: controller)
    try await wait { presentation.conversation?.isPrepared == true }
    let conversation = try #require(presentation.conversation)
    conversation.updateText("An unfinished thought")
    #expect(!(await conversation.flushDraft()))
    await presentation.close()
    #expect(presentation.isPresented)
    #expect(conversation.draftSaveState == .failed)
    #expect(conversation.activeDraft.text == "An unfinished thought")
    #expect(await conversation.flushDraft())
    await presentation.close()
    #expect(!presentation.isPresented)
    let restored = CommentConversationController(
      scope: conversation.scope, userID: 1, gistOwnerID: 1,
      remote: fixture.remote, store: fixture.store)
    await restored.prepare()
    #expect(restored.activeDraft.text == "An unfinished thought")
    #expect(await fixture.remote.createdBodies.isEmpty)
  }

  @Test func reopeningPassagesReplacesTheSelectedRootWithoutRequestingFocus() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    await presentation.prepareAnnotations(for: controller, showsInline: true)
    for id: Int64 in [200, 300, 200] {
      let revision = presentation.threadRevealRevision
      presentation.open(for: controller, origin: .reading, rootID: id)
      try await wait { presentation.selectedRootID == id }
      #expect(presentation.isPresented)
      #expect(presentation.threadRevealRevision == revision + 1)
      #expect(presentation.focusRequest == 0)
      #expect(presentation.documentMode == .reading)
      await presentation.close()
      #expect(!presentation.isPresented)
      #expect(presentation.selectedRootID == nil)
      presentation.didDismiss()
    }
  }

  @Test func initialReadFailureCanCloseWithoutBlockingAccountPersistence() async throws {
    let fixture = NotebookCommentsCaptureFixture(scenario: "store-unavailable")
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    presentation.open(for: controller)
    try await wait { presentation.conversation?.draftSaveState == .failed }
    #expect(presentation.conversation?.isPrepared == false)
    await presentation.close()
    #expect(!presentation.isPresented)
    #expect(await presentation.flushDrafts())
    #expect(await fixture.remote.createdBodies.isEmpty)
  }

  @Test func queuedSheetWaitsForNativeDismissalAndRunsOnlyOnce() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    presentation.open(for: controller)
    try await wait { presentation.conversation?.isPrepared == true }
    var presentations = 0
    presentation.performAfterClosing { presentations += 1 }
    try await wait { !presentation.isPresented }
    #expect(presentations == 0)
    presentation.didDismiss()
    #expect(presentations == 1)
    presentation.didDismiss()
    #expect(presentations == 1)
  }

  @Test func aResetCancelsAQueuedPresentationAndStaleAnnotationCallbacks() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let controller = try await open(fixture)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    presentation.open(for: controller)
    try await wait { presentation.conversation?.isPrepared == true }
    var presented = false
    presentation.performAfterClosing { presented = true }
    try await wait { !presentation.isPresented }
    presentation.reset()
    presentation.didDismiss()
    presentation.open(for: controller, rootID: 300)
    #expect(!presented)
    #expect(!presentation.isPresented)
    #expect(presentation.conversation == nil)
  }

  @Test func sourceAccessDoesNotPreventAConversationOnAStarredGist() async throws {
    let fixture = NotebookCommentsCaptureFixture()
    let controller = try await open(fixture, gistID: "shared")
    #expect(!controller.document.chrome.access.canEdit)
    let presentation = NotebookCommentsPresentation(notebook: fixture.notebook, provider: fixture.comments)
    presentation.activate(controller)
    presentation.open(for: controller, origin: .source)
    try await wait { presentation.conversation?.comments != nil }
    #expect(presentation.isPresented)
    #expect(presentation.documentMode == .reading)
    #expect(presentation.conversation?.composer.canEdit == true)
    await presentation.close()
  }

  private func open(
    _ fixture: NotebookCommentsCaptureFixture, gistID: String = "ideas", filename: String = "README.md"
  ) async throws -> NotebookSessionController {
    await fixture.notebook.start()
    await fixture.notebook.open(gistID: gistID, filename: filename)
    let document = try #require(fixture.notebook.loadedDocument)
    let draft = try await fixture.notebook.openDraft(for: document)
    return NotebookSessionController(document: document, draft: draft, notebook: fixture.notebook)
  }

  private func wait(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Comments presentation did not reach the expected state.")
    throw CaptureTestError.timedOut
  }

  private enum CaptureTestError: Error { case timedOut }
}
#endif
