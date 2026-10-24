import Foundation
import GistPadEditor
import GistPadInterface
import SwiftUI
import Testing
import UIKit

@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct NotebookSessionTests {
  @Test func cancelledURLInspectionDoesNotBecomeAVisibleGitHubFailure() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.failNextInspection(with: URLError(.cancelled))
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError == nil)
    #expect(await provider.inspectionGenerations == [0, 0])
    #expect(controller.saveState == .savedToGitHub)
    #expect(controller.session.text == "Base")
    #expect(await provider.publishCount == 0)
  }

  @Test func aOneOffConnectionLossRetriesBeforeShowingAnError() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.failNextInspection(with: URLError(.networkConnectionLost))
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError == nil)
    #expect(await provider.inspectionGenerations == [0, 0])
    #expect(controller.session.text == "Base")
    #expect(await provider.publishCount == 0)
  }

  @Test func aWrappedURLCancellationAlsoRetriesWithoutWarning() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.failNextInspection(
      with: ProviderReadFailure(underlying: URLError(.cancelled)))
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError == nil)
    #expect(await provider.inspectionGenerations == [0, 0])
    #expect(controller.session.text == "Base")
  }

  @Test func aCancelledPresentationNeverRetriesOrShowsItsProviderFailure() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.holdNextInspection()
    await provider.failNextInspection(
      with: ProviderReadFailure(underlying: URLError(.cancelled)))
    let check = Task { await controller.inspectRemoteChanges() }
    await provider.waitForInspection()
    check.cancel()
    await provider.releaseInspection()
    await check.value
    #expect(controller.remoteInspectionError == nil)
    #expect(!controller.isInspectingRemote)
    #expect(await provider.inspectionGenerations == [0])
  }

  @Test func aSupersededReadRetriesTheLatestDurableGenerationWithoutReplacingSource() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.holdNextInspection()
    let check = Task { await controller.inspectRemoteChanges() }
    await provider.waitForInspection()
    edit(controller, to: "A newer retained draft")
    controller.session.textView.selectedRange = .init(location: 3, length: 2)
    #expect(await controller.waitForLocalSave())
    await provider.releaseInspection()
    await check.value
    #expect(await provider.inspectionGenerations == [0, 1])
    #expect(controller.remoteInspectionError == nil)
    #expect(controller.session.text == "A newer retained draft")
    #expect(controller.session.textView.selectedRange == .init(location: 3, length: 2))
    #expect(try await provider.snapshot().text == "A newer retained draft")
    #expect(await provider.publishCount == 0)
  }

  @Test func persistentConnectionFailureStaysVisibleUntilARealRecoveryCompletes() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    for _ in 0..<3 { await provider.failNextInspection(with: URLError(.notConnectedToInternet)) }
    await controller.inspectRemoteChanges()
    let problem = try #require(controller.remoteInspectionError)
    #expect(await provider.inspectionGenerations.count == 3)
    #expect(controller.saveState == .savedToGitHub)
    #expect(controller.session.text == "Base")
    for _ in 0..<3 { await provider.failNextInspection(with: URLError(.notConnectedToInternet)) }
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError == problem)
    #expect(await provider.inspectionGenerations.count == 6)
    await provider.holdNextInspection()
    let retry = Task { await controller.inspectRemoteChanges() }
    await provider.waitForInspection()
    #expect(controller.isInspectingRemote)
    #expect(controller.remoteInspectionError == problem)
    await provider.releaseInspection()
    await retry.value
    #expect(controller.remoteInspectionError == nil)
    #expect(!controller.isInspectingRemote)
    #expect(await provider.inspectionGenerations.count == 7)
    #expect(await provider.publishCount == 0)
  }

  @Test func repeatedCancellationRemainsQuietEvenAfterTheRetryBudgetIsExhausted() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    for _ in 0..<3 { await provider.failNextInspection(with: URLError(.cancelled)) }
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError == nil)
    #expect(await provider.inspectionGenerations.count == 3)
    #expect(!controller.isInspectingRemote)
  }

  @Test func authenticationAndRateLimitsAreActionableWithoutRepeatedRequests() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.failNextInspection(with: GitHubClientError.http(status: 401, retryAfter: nil))
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionProblem?.recovery == .reconnect)
    #expect(await provider.inspectionGenerations.count == 1)
    let retryAfter = Date.now.addingTimeInterval(600)
    await provider.failNextInspection(
      with: GitHubClientError.http(status: 429, retryAfter: retryAfter))
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionProblem?.retryAfter == retryAfter)
    #expect(controller.remoteInspectionProblem?.recovery == .retry)
    #expect(await provider.inspectionGenerations.count == 2)
    await controller.inspectRemoteChanges()
    #expect(await provider.inspectionGenerations.count == 2)
    #expect(controller.remoteInspectionError != nil)
    #expect(await provider.publishCount == 0)
  }

  @Test func anExpiredRateLimitCanRecoverWithoutChangingTheNote() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    let deadline = Date.now.addingTimeInterval(-1)
    await provider.failNextInspection(
      with: GitHubClientError.http(status: 429, retryAfter: deadline))
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionProblem?.retryAfter == deadline)
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError == nil)
    #expect(await provider.inspectionGenerations == [0, 0])
    #expect(controller.session.text == "Base")
    #expect(await provider.publishCount == 0)
  }

  @Test func aNonReviewProviderResultFailsHonestlyWithoutPretendingToBeStale() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    await provider.returnDraftInsteadOfReview()
    await controller.inspectRemoteChanges()
    #expect(controller.remoteInspectionError != nil)
    #expect(await provider.inspectionGenerations == [0])
    #expect(controller.session.text == "Base")
    #expect(controller.saveState == .savedToGitHub)
    #expect(await provider.publishCount == 0)
  }

  @Test func saveSafetyIssuesTakePrecedenceOverTheRemoteCheckFooter() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    for _ in 0..<3 { await provider.failNextInspection(with: URLError(.notConnectedToInternet)) }
    await controller.inspectRemoteChanges()
    guard case .problem = controller.remoteInspectionStatus else {
      Issue.record("The ordinary persistent check failure needs its quiet footer.")
      return
    }
    edit(controller, to: "Keep this newer source")
    #expect(await controller.waitForLocalSave())
    await provider.setRemoteContent("A conflicting remote edit")
    await controller.inspectRemoteChanges()
    #expect(controller.saveState == .remoteChange)
    #expect(controller.remoteInspectionStatus == .idle)
    #expect(controller.session.text == "Keep this newer source")
    #expect(await provider.publishCount == 0)
  }

  @Test func cachedHomeRefreshRetriesAConnectionBlipWithoutAnAttentionState() async throws {
    let (model, provider) = try makeRefreshModel()
    await model.start()
    #expect(model.cachedLibrary != nil)
    let initialRequests = await provider.refreshCount
    await provider.failNextRefresh(with: URLError(.networkConnectionLost))
    await model.refresh()
    #expect(await provider.refreshCount == initialRequests + 2)
    #expect(model.library.loadState == .ready)
    #expect(model.library.gitHubStatus == .idle)
    #expect(model.remoteRefreshProblem == nil)
  }

  @Test func homeKeepsItsProblemDuringRetryAndClearsOnlyAfterRecovery() async throws {
    let (model, provider) = try makeRefreshModel()
    await model.start()
    for _ in 0..<3 { await provider.failNextRefresh(with: URLError(.notConnectedToInternet)) }
    await model.refresh()
    let problem = try #require(model.remoteRefreshProblem)
    guard case .problem(let status) = model.library.gitHubStatus else {
      Issue.record("A persistent cached refresh problem needs the shared attention control.")
      return
    }
    #expect(status.message == problem.message)
    #expect(!status.isRecovering)
    await provider.holdNextRefresh()
    let retry = Task { await model.refresh() }
    await provider.waitForRefresh()
    #expect(model.isRefreshingRemote)
    #expect(model.remoteRefreshProblem == problem)
    guard case .problem(let recovering) = model.library.gitHubStatus else {
      await provider.releaseRefresh()
      await retry.value
      Issue.record("Retry must not replace the unresolved problem with a spinner.")
      return
    }
    #expect(recovering.isRecovering)
    await provider.releaseRefresh()
    await retry.value
    #expect(model.library.loadState == .ready)
    #expect(model.library.gitHubStatus == .idle)
    #expect(model.remoteRefreshProblem == nil)
  }

  @Test func cancellingAHomeRefreshRestoresItsCachedStateWithoutWarning() async throws {
    let (model, provider) = try makeRefreshModel()
    await model.start()
    let initialRequests = await provider.refreshCount
    await provider.holdNextRefresh()
    await provider.failNextRefresh(
      with: ProviderReadFailure(underlying: URLError(.cancelled)))
    let refresh = Task { await model.refresh() }
    await provider.waitForRefresh()
    refresh.cancel()
    await provider.releaseRefresh()
    await refresh.value
    #expect(await provider.refreshCount == initialRequests + 1)
    #expect(model.library.loadState == .ready)
    #expect(model.library.gitHubStatus == .idle)
    #expect(model.remoteRefreshProblem == nil)
    #expect(!model.isRefreshingRemote)
  }

  @Test func firstLoadWithoutCacheKeepsItsExplicitFailureSurface() async throws {
    let (model, provider) = try makeRefreshModel()
    for _ in 0..<3 { await provider.failNextRefresh(with: URLError(.notConnectedToInternet)) }
    await model.start()
    #expect(model.cachedLibrary == nil)
    guard case .failed = model.library.loadState else {
      Issue.record("A first load without cache cannot look like an empty successful notebook.")
      return
    }
    #expect(model.library.gitHubStatus == .idle)
    await model.refresh()
    #expect(model.library.loadState == .ready)
    #expect(model.remoteRefreshProblem == nil)
  }

  @Test func explicitlyConfirmingAnUnboundCreationPreservesTheEditorAndUsesOneManualPost() async throws {
    let (controller, provider) = try await makeController(autosave: true, uncertainCreation: true)
    let identity = controller.session.viewIdentity
    let text = controller.session.text
    let generation = controller.session.generation
    controller.session.textView.selectedRange = .init(location: 2, length: 3)
    #expect(controller.saveState == .creationUncertain)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    try await controller.resolveUncertainCreation(.publishAsNew, expectedGeneration: generation)
    #expect(controller.session.viewIdentity == identity)
    #expect(controller.session.text.utf8.elementsEqual(text.utf8))
    #expect(controller.session.generation == generation)
    #expect(controller.session.textView.selectedRange == .init(location: 2, length: 3))
    #expect(controller.draft.attemptedGeneration == nil)
    #expect(controller.saveState == .savedLocally)
    #expect(await provider.publishCount == 0)
    let publication = Task { await controller.publish() }
    await provider.waitForPublish()
    #expect(await provider.publishCount == 1)
    await provider.releasePublish()
    await publication.value
    #expect(await provider.publishCount == 1)
    #expect(await provider.publicationReasons == [.manual])
    #expect(controller.draft.gistID == "synthetic")
    #expect(controller.saveState == .savedToGitHub)
    #expect(controller.session.viewIdentity == identity)
  }

  @Test func discardingAnUnboundCreationRemovesOnlyItsLocalCopyAndNeverPublishes() async throws {
    let (controller, provider) = try await makeController(autosave: true, uncertainCreation: true)
    let other = try await provider.store.newDraft(
      accountID: controller.draft.accountID, githubUserID: 1, text: "Keep this other copy")
    try await controller.resolveUncertainCreation(
      .discard, expectedGeneration: controller.session.generation)
    await #expect(throws: DraftError.notFound) { _ = try await provider.snapshot() }
    #expect(
      try await provider.store.draft(id: other.id, accountID: other.accountID).text
        == "Keep this other copy")
    #expect(await provider.publishCount == 0)
    #expect(controller.updateAutosave(isForeground: true) == nil)
  }

  @Test func aCreationChoiceCannotUseAnOlderGeneration() async throws {
    let (controller, provider) = try await makeController(autosave: true, uncertainCreation: true)
    let oldGeneration = controller.session.generation
    edit(controller, to: "A newer unbound local thought")
    #expect(await controller.waitForLocalSave())
    for choice in [NotebookCreationChoice.publishAsNew, .discard] {
      await #expect(throws: DraftError.staleGeneration) {
        try await controller.resolveUncertainCreation(choice, expectedGeneration: oldGeneration)
      }
    }
    #expect(try await provider.snapshot().text == "A newer unbound local thought")
    #expect(controller.saveState == .creationUncertain)
    #expect(await provider.publishCount == 0)
  }

  @Test func productionFocusArrangementRetainsTheEditorSelectionAndUndo() async throws {
    let (controller, _) = try await makeController()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(
      rootView: FocusNoteFixture(controller: controller, focused: false))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(200))
    let view = controller.session.textView
    view.becomeFirstResponder()
    view.selectedRange = NSRange(location: 2, length: 0)
    view.undoManager?.beginUndoGrouping()
    view.insertText("日本語 👩🏽‍💻")
    view.undoManager?.endUndoGrouping()
    let text = view.text
    let selection = view.selectedRange
    for focused in [true, false, true, false] {
      host.rootView = FocusNoteFixture(controller: controller, focused: focused)
      try await Task.sleep(for: .milliseconds(100))
      host.view.layoutIfNeeded()
      #expect(controller.session.textView === view)
      #expect(view.window === window)
      #expect(view.text == text)
      #expect(view.selectedRange == selection)
    }
    view.undoManager?.undo()
    #expect(view.text == "Base")
  }

  @Test func retainedRemoteChangeIsReviewedWithoutReplacingSourceSelectionOrUndo() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    let identity = controller.session.viewIdentity
    edit(controller, to: "Retained local draft")
    controller.session.textView.selectedRange = NSRange(location: 4, length: 3)
    #expect(await controller.waitForLocalSave())
    await provider.setRemoteContent("Changed in the web app")
    await controller.inspectRemoteChanges()
    #expect(controller.session.viewIdentity == identity)
    #expect(controller.session.text == "Retained local draft")
    #expect(controller.session.textView.selectedRange == NSRange(location: 4, length: 3))
    #expect(controller.saveState == .remoteChange)
    let review = try controller.reviewContext()
    #expect(review.conflict.remote == "Changed in the web app")
    #expect(controller.updateAutosave(isForeground: true) == nil)
    #expect(await provider.publishCount == 0)
    edit(controller, to: "Typing continues safely")
    #expect(await controller.waitForLocalSave())
    #expect(controller.saveState == .remoteChange)
  }

  @Test(arguments: [true, false])
  func restoredPublicationInspectionAdoptsOnlyAnExactMatchWithoutPublishing(matches: Bool) async throws {
    let (controller, provider) = try await makeController(
      generation: 1, autosave: true, uncertainPublication: true)
    #expect(controller.saveState == .publicationUncertain)
    let editor = controller.session.textView
    let text = controller.session.text
    let generation = controller.session.generation
    editor.selectedRange = NSRange(location: 4, length: 3)
    let undo = editor.undoManager?.canUndo
    await provider.setRemoteContent(matches ? text : "Another remote value")
    await controller.inspectRemoteChanges()
    #expect(controller.session.textView === editor)
    #expect(controller.session.text.utf8.elementsEqual(text.utf8))
    #expect(controller.session.generation == generation)
    #expect(editor.selectedRange == NSRange(location: 4, length: 3))
    #expect(editor.undoManager?.canUndo == undo)
    #expect(controller.saveState == (matches ? .savedToGitHub : .publicationUncertain))
    #expect(controller.document.draft?.state == controller.draft.state)
    #expect(controller.draft.attemptedGeneration == (matches ? nil : 1))
    #expect(controller.remoteInspectionError == nil)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    #expect(await provider.publishCount == 0)
  }

  @Test func autosavePublishesOnlyADurableQuietForegroundGeneration() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "Quiet accepted draft")
    #expect(await controller.waitForLocalSave())
    let task = try #require(controller.updateAutosave(isForeground: true))
    await task.value
    #expect(await provider.publishCount == 1)
    #expect(await provider.publicationReasons == [.autosave])
    #expect(controller.saveState == .savedToGitHub)
  }

  @Test func autosaveOffAndLeavingTheForegroundCancelOnlyTheTimer() async throws {
    let (disabled, disabledProvider) = try await makeController(autosave: false)
    edit(disabled, to: "Keep local")
    #expect(await disabled.waitForLocalSave())
    #expect(disabled.updateAutosave(isForeground: true) == nil)
    #expect(disabled.updateAutosave(isForeground: false) == nil)
    #expect(await disabledProvider.publishCount == 0)

    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "Background local draft")
    #expect(await controller.waitForLocalSave())
    let pending = try #require(controller.updateAutosave(isForeground: true))
    #expect(controller.updateAutosave(isForeground: false) == nil)
    await pending.value
    #expect(await provider.publishCount == 0)
    #expect(try await provider.snapshot().text == "Background local draft")
  }

  @Test func backgroundSavesEveryDurableSessionRegardlessOfAutosavePreference() async throws {
    let (disabled, disabledProvider) = try await makeController(autosave: false)
    let (enabled, enabledProvider) = try await makeController(autosave: true)
    edit(disabled, to: "Publish on hide, with autosave off")
    edit(enabled, to: "Publish on hide, with autosave on")
    let disabledIdentity = disabled.session.viewIdentity
    await NotebookLifecycle.saveOnBackground([disabled, enabled], shouldContinue: { true })
    #expect(await disabledProvider.publishCount == 1)
    #expect(await enabledProvider.publishCount == 1)
    #expect(await disabledProvider.publicationReasons == [.background])
    #expect(await enabledProvider.publicationReasons == [.background])
    #expect(try await disabledProvider.snapshot().baseContent == disabled.session.text)
    #expect(try await enabledProvider.snapshot().baseContent == enabled.session.text)
    #expect(disabled.saveState == .savedToGitHub)
    #expect(enabled.saveState == .savedToGitHub)
    #expect(disabled.session.viewIdentity == disabledIdentity)
  }

  @Test func leavingANotePublishesImmediatelyOnlyWithAutosaveEnabled() async throws {
    let (enabled, provider) = try await makeController(autosave: true)
    edit(enabled, to: "Leaving this note")
    #expect(await enabled.waitForLocalSave())
    let timer = try #require(enabled.updateAutosave(isForeground: true))
    await enabled.finishLeavingNote()
    await timer.value
    #expect(timer.isCancelled)
    #expect(await provider.publishCount == 1)
    #expect(await provider.publicationReasons == [.autosave])
    #expect(try await provider.snapshot().baseContent == "Leaving this note")

    let (disabled, disabledProvider) = try await makeController(autosave: false)
    edit(disabled, to: "Retain this local note")
    #expect(await disabled.waitForLocalSave())
    disabled.updateAutosave(isForeground: true)
    await disabled.finishLeavingNote()
    #expect(await disabledProvider.publishCount == 0)
    #expect(try await disabledProvider.snapshot().text == "Retain this local note")
  }

  @Test func backgroundSkipsReadOnlyConflictCompositionWritingToolsAndRecovery() async throws {
    for condition in ["read-only", "conflict", "composition", "writing-tools", "recovery"] {
      let (controller, provider) = try await makeController(
        generation: condition == "read-only" ? 1 : 0,
        autosave: false, isReadOnly: condition == "read-only")
      if condition != "read-only" {
        edit(controller, to: "Preserved \(condition) draft")
        #expect(await controller.waitForLocalSave())
      }
      switch condition {
      case "conflict":
        await provider.setRemoteContent("Changed on the web")
        await controller.inspectRemoteChanges()
        #expect(controller.saveState == .remoteChange)
      case "composition":
        controller.session.textView.setMarkedText(
          "にほんご", selectedRange: NSRange(location: 4, length: 0))
        controller.session.textViewDidChangeSelection(controller.session.textView)
      case "writing-tools":
        controller.session.textViewWritingToolsWillBegin(controller.session.textView)
      case "recovery": controller.markRecovery()
      default: break
      }
      await NotebookLifecycle.saveOnBackground([controller], shouldContinue: { true })
      #expect(await provider.publishCount == 0, "Background must defer \(condition).")
      #expect(try await provider.snapshot().text.isEmpty == false)
      if condition == "composition" {
        controller.session.textView.unmarkText()
        controller.session.textViewDidChangeSelection(controller.session.textView)
      } else if condition == "writing-tools" {
        controller.session.textViewWritingToolsDidEnd(controller.session.textView)
      }
    }
  }

  @Test func expiryDuringTheFreshReadStopsTheWriteAndRemainingBackgroundBatch() async throws {
    let (first, provider) = try await makeController(autosave: false)
    let (second, secondProvider) = try await makeController(autosave: true)
    edit(first, to: "First durable draft")
    edit(second, to: "Second durable draft")
    let allowance = BackgroundTestAllowance()
    await provider.holdBeforeValidation()
    let saving = Task {
      await NotebookLifecycle.saveOnBackground(
        [first, second], shouldContinue: { allowance.isActive })
    }
    await provider.waitForPublish()
    allowance.isActive = false
    saving.cancel()
    await provider.releasePublish()
    await saving.value
    #expect(await provider.publishCount == 0)
    #expect(await secondProvider.publishCount == 0)
    #expect(try await provider.snapshot().text == "First durable draft")
    #expect(try await secondProvider.snapshot().text == "Second durable draft")
    #expect(first.saveState == .savedLocally)
    #expect(second.saveState == .savedLocally)
  }

  @Test func anUnavailableBackgroundLeaseStillFinishesLocalPersistence() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    edit(controller, to: "Save locally even when time is unavailable")
    await NotebookLifecycle.saveOnBackground([controller], shouldContinue: { false })
    #expect(await provider.persistedGenerations == [1])
    #expect(await provider.publishCount == 0)
    #expect(try await provider.snapshot().text == controller.session.text)
    #expect(controller.saveState == .savedLocally)
  }

  @Test func backgroundWaitsForAnExistingSaveThenPublishesNewerTyping() async throws {
    let (controller, provider) = try await makeController(autosave: false)
    edit(controller, to: "Earlier manual save")
    #expect(await controller.waitForLocalSave())
    let manual = Task { await controller.publish() }
    await provider.waitForPublish()
    edit(controller, to: "Latest accepted source")
    #expect(await controller.waitForLocalSave())
    let background = Task {
      await NotebookLifecycle.saveOnBackground([controller], shouldContinue: { true })
    }
    await Task.yield()
    #expect(await provider.publishCount == 1)
    await provider.releasePublish()
    await manual.value
    await background.value
    #expect(await provider.publishCount == 2)
    #expect(await provider.publicationReasons == [.manual, .background])
    #expect(try await provider.snapshot().baseContent == "Latest accepted source")
    #expect(controller.session.text == "Latest accepted source")
  }

  @Test func leaseExpirationCancelsItsOwnerOnceAndInvalidatesPublication() {
    let lease = NotebookBackgroundLease()
    var expirations = 0
    lease.onExpiration = { expirations += 1 }
    lease.expire()
    lease.expire()
    #expect(expirations == 1)
    #expect(!lease.isActive)
    #expect(lease.onExpiration == nil)
  }

  @Test func autosaveDefersCompositionWritingToolsAndRecovery() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "Accepted text")
    #expect(await controller.waitForLocalSave())
    controller.session.textView.setMarkedText(
      "にほんご", selectedRange: NSRange(location: 4, length: 0))
    controller.session.textViewDidChangeSelection(controller.session.textView)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    controller.session.textView.unmarkText()
    controller.session.textViewDidChangeSelection(controller.session.textView)
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    #expect(controller.updateAutosave(isForeground: true) == nil)
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    controller.markRecovery()
    #expect(controller.updateAutosave(isForeground: true) == nil)
    #expect(await provider.publishCount == 0)
  }

  @Test func autosaveCancelsAnOlderPauseAndPublishesOnlyTheLatestText() async throws {
    let (controller, provider) = try await makeController(autosave: true)
    edit(controller, to: "First draft")
    #expect(await controller.waitForLocalSave())
    let old = try #require(controller.updateAutosave(isForeground: true))
    edit(controller, to: "Latest draft")
    #expect(await controller.waitForLocalSave())
    let latest = try #require(controller.updateAutosave(isForeground: true))
    await old.value
    await latest.value
    #expect(await provider.publishCount == 1)
    #expect(try await provider.snapshot().baseContent == "Latest draft")
  }

  @Test func restoredGenerationsAndRapidEditsPersistInOrder() async throws {
    let (controller, provider) = try await makeController(generation: 7)
    #expect(controller.session.generation == 7)
    for text in ["First", "Second", "日本語 👨‍👩‍👧‍👦"] { edit(controller, to: text) }
    #expect(await controller.waitForLocalSave())
    let saved = try await provider.snapshot()
    #expect(saved.generation == 10)
    #expect(saved.text.utf8.elementsEqual("日本語 👨‍👩‍👧‍👦".utf8))
    #expect(await provider.persistedGenerations == [8, 9, 10])
    #expect(controller.saveState == .savedLocally)
  }

  @Test func aPublishResponseCannotReplaceNewerTyping() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "The manually saved generation")
    #expect(await controller.waitForLocalSave())
    let publishing = Task { await controller.publish() }
    await provider.waitForPublish()
    edit(controller, to: "Newer typing stays local")
    #expect(await controller.waitForLocalSave())
    await provider.releasePublish()
    await publishing.value
    #expect(controller.session.text == "Newer typing stays local")
    #expect(controller.draft.text == "Newer typing stays local")
    #expect(controller.draft.baseContent == "The manually saved generation")
    #expect(controller.saveState == .savedLocally)
  }

  @Test func aLocalWriteFailureBlocksPublishing() async throws {
    let (controller, provider) = try await makeController()
    await provider.failPersistence()
    edit(controller, to: "Keep this in the editor")
    #expect(!(await controller.waitForLocalSave()))
    await controller.publish()
    #expect(await provider.publishCount == 0)
    #expect(controller.session.text == "Keep this in the editor")
    guard case .localFailure = controller.saveState else {
      Issue.record("An unacknowledged local write must remain an explicit failure.")
      return
    }
    #expect(controller.remoteInspectionStatus == .idle)
  }

  @Test func writingToolsPersistsOnlyTheFinalChoiceAndNeverPublishesPreviews() async throws {
    let (controller, provider) = try await makeController(generation: 7)
    let source = controller.session.text
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    edit(controller, to: "Temporary rewrite")
    #expect(controller.session.text == source)
    #expect(await provider.persistedGenerations.isEmpty)
    await controller.publish()
    #expect(await provider.publishCount == 0)
    edit(controller, to: "The accepted rewrite 日本語 👩🏽‍💻")
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    #expect(await provider.persistedGenerations == [8])
    #expect(try await provider.snapshot().text == "The accepted rewrite 日本語 👩🏽‍💻")
    #expect(controller.saveState == .savedLocally)
    #expect(await provider.publishCount == 0)

    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    edit(controller, to: "A rejected rewrite")
    edit(controller, to: "The accepted rewrite 日本語 👩🏽‍💻")
    controller.session.textViewWritingToolsDidEnd(controller.session.textView)
    #expect(await controller.waitForLocalSave())
    #expect(await provider.persistedGenerations == [8])
  }

  @Test func lostOwnershipBlocksFurtherPublication() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "A local edit")
    #expect(await controller.waitForLocalSave())
    await provider.rejectPublication()
    await controller.publish()
    guard case .publicationBlocked = controller.saveState else {
      Issue.record("Lost ownership must not become a retryable network failure.")
      return
    }
    #expect(!controller.saveState.canPublish)
  }

  @Test func durableInsertionIsOneNativeUndoAndNeverPublishes() async throws {
    let (controller, provider) = try await makeController()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let identity = ObjectIdentifier(controller.session.textView)
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(
        location: 4, length: 0, expectedText: "",
        replacement: "\n![Image](https://example.test/image.png)"))
    try await controller.applyDurableEdit(command) {
      try await provider.store.apply(command)
    }
    #expect(controller.session.text == "Base\n![Image](https://example.test/image.png)")
    #expect(controller.session.generation == 1)
    #expect(ObjectIdentifier(controller.session.textView) == identity)
    #expect(controller.session.textView.undoManager?.canUndo == true)
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == "Base")
    #expect(await controller.waitForLocalSave())
    #expect(try await provider.snapshot().text == "Base")
    #expect(await provider.publishCount == 0)
  }

  @Test func aFailedDurableCommitLeavesSourceSelectionAndGenerationUntouched() async throws {
    let (controller, _) = try await makeController()
    controller.session.textView.selectedRange = NSRange(location: 2, length: 1)
    let selection = controller.session.textView.selectedRange
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(location: 4, length: 0, expectedText: "", replacement: " changed"))
    await #expect(throws: URLError.self) {
      try await controller.applyDurableEdit(command) { throw URLError(.cannotWriteToFile) }
    }
    #expect(controller.session.text == "Base")
    #expect(controller.session.generation == 0)
    #expect(controller.session.textView.selectedRange == selection)
    #expect(controller.session.textView.isEditable)
  }

  @Test func staleDurableCommandsCannotReplaceNewerTyping() async throws {
    let (controller, provider) = try await makeController()
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(location: 4, length: 0, expectedText: "", replacement: " changed"))
    edit(controller, to: "Newer 日本語")
    #expect(await controller.waitForLocalSave())
    await #expect(throws: DraftError.staleGeneration) {
      try await controller.applyDurableEdit(command) {
        try await provider.store.apply(command)
      }
    }
    #expect(controller.session.text == "Newer 日本語")
    #expect(try await provider.snapshot().text == "Newer 日本語")
  }

  @Test func recoveryEditsStayLocalAndCannotRecreateADeletedGist() async throws {
    let (controller, provider) = try await makeController()
    controller.markRecovery()
    edit(controller, to: "A recoverable local edit")
    #expect(await controller.waitForLocalSave())
    #expect(!controller.saveState.canPublish)
    await controller.publish()
    #expect(await provider.publishCount == 0)
    #expect(try await provider.snapshot().text == "A recoverable local edit")
  }

  @Test func destructiveActionsLockInputUntilLocalPersistenceFinishes() async throws {
    let (controller, provider) = try await makeController()
    edit(controller, to: "Finish this local generation first")
    try controller.beginDestructiveAction()
    #expect(!controller.session.textView.isEditable)
    #expect(!controller.canMutate)
    #expect(await controller.waitForLocalSave())
    #expect(try await provider.snapshot().text == "Finish this local generation first")
    controller.endDestructiveAction()
    #expect(controller.session.textView.isEditable)
    #expect(controller.canMutate)
  }

  @Test func publishedLinksUseGistPadsShareRouteAndKeepLocalChangesSeparate() async throws {
    let (controller, _) = try await makeController()
    let links = try #require(try controller.savedLinks())
    #expect(links.shareURL.absoluteString == "https://gistpad.dev/#/share/synthetic/README.md")
    #expect(links.githubURL.absoluteString == "https://gist.github.com/synthetic")
    #expect(links.isSecret)
    #expect(!controller.hasUnpublishedChanges)
    edit(controller, to: "Not published")
    #expect(controller.hasUnpublishedChanges)
    #expect(await controller.waitForLocalSave())
    #expect(try controller.savedLinks()?.hasUnpublishedChanges == true)
  }

  @Test func sourceDiffsDistinguishUnicodeNormalizationAndMissingFiles() {
    let lines = NotebookDiffLine.changes(from: "cafe\u{301}", to: "caf\u{e9}")
    #expect(lines.count == 2)
    #expect(lines[0].isAddition == false)
    #expect(lines[0].text.utf8.elementsEqual("cafe\u{301}".utf8))
    #expect(lines[1].isAddition)
    let missing = NotebookDiffLine.changes(from: nil, to: "A newly created file")
    #expect(missing.count == 1)
    #expect(missing[0].isAddition)
  }

  @Test func keepingMyReviewedDraftDoesNotCreateAFakeGenerationOrUndo() async throws {
    let (controller, provider) = try await makeController(generation: 1, autosave: true)
    #expect(controller.document.chrome.isAutoSaveEnabled)
    _ = try await provider.introduceConflict(remote: "From GitHub")
    try await controller.refreshMetadata()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let undo = try #require(controller.session.textView.undoManager)
    undo.removeAllActions()
    let original = controller.session.text
    try await controller.commitMutation(
      .init(
        range: NSRange(location: 0, length: original.utf16.count), expected: original,
        replacement: original),
      expectedGeneration: 1
    ) {
      try await provider.store.resolveConflict(
        id: controller.draft.id, accountID: controller.draft.accountID,
        expectedGeneration: 1, text: original, generation: 1)
    }
    #expect(controller.session.generation == 1)
    #expect(!undo.canUndo)
    #expect(controller.saveState == .savedLocally)
    #expect(!controller.document.chrome.isAutoSaveEnabled)
    #expect(controller.saveState.canPublish)
    #expect(
      try await provider.store.recoveries(
        id: controller.draft.id, accountID: controller.draft.accountID
      ).count == 1)
    #expect(await provider.publishCount == 0)
  }

  @Test func adoptingAReviewedVersionIsOneRecoverableLocalUndo() async throws {
    let (controller, provider) = try await makeController(generation: 1, autosave: true)
    #expect(controller.document.chrome.isAutoSaveEnabled)
    _ = try await provider.introduceConflict(remote: "From GitHub 日本語")
    try await controller.refreshMetadata()
    let window = try EditorContinuityTests().host(controller.session)
    defer { window.isHidden = true }
    let original = controller.session.text
    try await controller.commitMutation(
      .init(
        range: NSRange(location: 0, length: original.utf16.count), expected: original,
        replacement: "From GitHub 日本語"),
      expectedGeneration: 1
    ) {
      try await provider.store.resolveConflict(
        id: controller.draft.id, accountID: controller.draft.accountID,
        expectedGeneration: 1, text: "From GitHub 日本語", generation: 2)
    }
    #expect(controller.session.text == "From GitHub 日本語")
    #expect(controller.saveState == .savedLocally)
    #expect(!controller.document.chrome.isAutoSaveEnabled)
    #expect(controller.saveState.canPublish)
    #expect(await provider.publishCount == 0)
    controller.session.textView.undoManager?.undo()
    #expect(controller.session.text == original)
    #expect(await controller.waitForLocalSave())
    #expect(try await provider.snapshot().text == original)
  }

  @Test func staleReviewCannotOverwriteNewerSource() async throws {
    let (controller, provider) = try await makeController(generation: 1)
    _ = try await provider.introduceConflict(remote: "From GitHub")
    try await controller.refreshMetadata()
    let old = try controller.reviewContext()
    edit(controller, to: "A newer local choice")
    #expect(await controller.waitForLocalSave())
    #expect(!old.matches(controller.draft))
    await #expect(throws: NotebookActionError.staleReview) {
      try await controller.applyReview(old, text: "From GitHub")
    }
    #expect(controller.session.text == "A newer local choice")
    #expect(controller.draft.state != .savedToGitHub)
    #expect(await provider.publishCount == 0)
  }

  @Test func persistedPublicationUncertaintyIsNotLostToAGenericNetworkError() async throws {
    let (controller, provider) = try await makeController(generation: 1)
    await provider.failPublication(with: .failed(.publicationUncertain))
    await controller.publish()
    #expect(controller.saveState == .publicationUncertain)
    #expect(controller.draft.state == .failed(.publicationUncertain))
    #expect(!controller.saveState.canPublish)
  }

  @Test func writingToolsBlocksDurableInsertionsBeforeTheirCommit() async throws {
    let (controller, provider) = try await makeController()
    controller.session.textViewWritingToolsWillBegin(controller.session.textView)
    defer { controller.session.textViewWritingToolsDidEnd(controller.session.textView) }
    let command = SharedDraftCommand(
      accountID: controller.draft.accountID, draftID: controller.draft.id,
      expectedGeneration: 0,
      edit: .init(location: 4, length: 0, expectedText: "", replacement: " image"))
    await #expect(throws: SourceMutation.MutationError.compositionActive) {
      try await controller.applyDurableEdit(command) { try await provider.store.apply(command) }
    }
    #expect(controller.session.text == "Base")
    #expect(try await provider.snapshot().generation == 0)
  }

  private func edit(_ controller: NotebookSessionController, to text: String) {
    controller.session.textView.text = text
    controller.session.textViewDidChange(controller.session.textView)
  }

  private func makeRefreshModel() throws -> (NotebookModel, SessionNotebookProvider) {
    let provider = SessionNotebookProvider(
      store: try DraftStore.open(inMemory: true), id: UUID(), accountID: UUID(), autosave: false)
    return (
      NotebookModel(
        provider: provider, remoteReadRetryDelays: [.milliseconds(1), .milliseconds(1)]),
      provider)
  }

  private func makeController(
    generation: UInt64 = 0, autosave: Bool? = nil, isReadOnly: Bool = false,
    uncertainPublication: Bool = false, uncertainCreation: Bool = false
  ) async throws -> (NotebookSessionController, SessionNotebookProvider) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let gist = try decoder.decode(
      Gist.self,
      from: Data(
        """
        {"id":"synthetic","description":"Session fixture","public":false,
        "created_at":"2026-10-23T00:00:00Z","updated_at":"2026-10-23T00:00:00Z",
        "owner":{"id":\(isReadOnly ? 99 : 1),"login":"fixture"},
        "files":{"README.md":{"filename":"README.md","content":"Base"}}}
        """.utf8))
    let accountID = UUID()
    let store = try DraftStore.open(inMemory: true)
    var draft: DraftSnapshot
    if uncertainCreation {
      draft = try await store.newDraft(
        accountID: accountID, githubUserID: 1, text: "Unbound private note")
    } else {
      draft = try await store.openDraft(
        accountID: accountID, githubUserID: 1, gistID: gist.id, filename: "README.md",
        description: "Session fixture", content: "Base", revision: "1")
    }
    if generation > 0 {
      draft = try await store.persist(
        id: draft.id, accountID: accountID, text: "Restored local draft", generation: generation)
    }
    if uncertainPublication || uncertainCreation {
      try await store.beginAttempt(
        id: draft.id, accountID: accountID, content: draft.text,
        generation: draft.generation, remote: draft.baseContent)
      try await store.setState(
        .failed(uncertainCreation ? .creationUncertain : .publicationUncertain),
        id: draft.id, accountID: accountID)
      draft = try await store.draft(id: draft.id, accountID: accountID)
    }
    let provider = SessionNotebookProvider(
      store: store, id: draft.id, accountID: accountID, autosave: autosave)
    let model = NotebookModel(provider: provider)
    if autosave != nil { await model.start() }
    let document = uncertainCreation
      ? NotebookDocument(draft: draft)
      : NotebookDocument(
        accountID: accountID, gist: gist, filename: "README.md", text: "Base",
        chrome: NoteChrome(
          title: "Session fixture", files: [.init(id: "README.md", filename: "README.md")],
          selectedFileID: "README.md"))
    return (
      NotebookSessionController(
        document: document, draft: draft, notebook: model, autosaveDelay: .milliseconds(30),
        remoteInspectionRetryDelays: [.milliseconds(1), .milliseconds(1)]),
      provider
    )
  }
}

@MainActor
private final class BackgroundTestAllowance {
  var isActive = true
}

private struct FocusNoteFixture: View {
  let controller: NotebookSessionController
  let focused: Bool

  var body: some View {
    NavigationStack {
      NoteScreen(
        document: controller.document.chrome, mode: .constant(.source),
        saveState: controller.saveState, isFocused: focused
      ) {
        MarkdownEditorView(session: controller.session)
      } preview: {
        Text("Preview companion")
      }
    }
  }
}

private actor SessionNotebookProvider: NotebookProviding {
  let store: DraftStore
  let id: UUID
  let accountID: UUID
  let autosave: Bool?
  private(set) var persistedGenerations: [UInt64] = []
  private(set) var publishCount = 0
  private(set) var publicationReasons: [PublishReason] = []
  private var persistenceFails = false
  private var publicationRejected = false
  private var publicationFailure: SaveState?
  private var remoteContent: String? = "Base"
  private var publishing: CheckedContinuation<Void, Never>?
  private var publishObserver: CheckedContinuation<Void, Never>?
  private var pausesBeforeValidation = false
  private var inspectionFailures: [any Error] = []
  private(set) var inspectionGenerations: [UInt64] = []
  private var inspectionGate: CheckedContinuation<Void, Never>?
  private var inspectionObserver: CheckedContinuation<Void, Never>?
  private var pausesInspection = false
  private var returnsDraftInsteadOfReview = false
  private var refreshFailures: [any Error] = []
  private(set) var refreshCount = 0
  private var refreshGate: CheckedContinuation<Void, Never>?
  private var refreshObserver: CheckedContinuation<Void, Never>?
  private var pausesRefresh = false

  init(store: DraftStore, id: UUID, accountID: UUID, autosave: Bool? = nil) {
    self.store = store
    self.id = id
    self.accountID = accountID
    self.autosave = autosave
  }

  func cachedAccount() -> NotebookAccount? {
    guard let autosave else { return nil }
    return NotebookAccount(
      id: accountID, login: "fixture", githubUserID: 1,
      preferences: .init(metadata: ["isAutoSaveEnabled": .bool(autosave)]))
  }
  func signIn() throws -> NotebookAccount { throw AccountError.signedOut }
  func refreshAccount() async throws -> NotebookAccount {
    refreshCount += 1
    if pausesRefresh {
      pausesRefresh = false
      await withCheckedContinuation {
        refreshGate = $0
        refreshObserver?.resume()
        refreshObserver = nil
      }
    }
    if !refreshFailures.isEmpty { throw refreshFailures.removeFirst() }
    guard let account = cachedAccount() else { throw AccountError.signedOut }
    return account
  }
  func gists(accountID: UUID) -> [Gist] { [] }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) throws -> Gist { throw GitHubClientError.missingFile }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    throw GitHubClientError.missingFile
  }
  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    try await snapshot()
  }

  func localState(accountID: UUID) async throws -> NotebookLocalState {
    NotebookLocalState(
      library: try await store.cachedLibrary(accountID: accountID),
      drafts: try await store.drafts(accountID: accountID))
  }
  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) async throws {
    try await store.cacheLibrary(
      owned: owned, starred: starred, preferences: account.preferences, accountID: account.id)
  }
  func createDraft(accountID: UUID) throws -> DraftSnapshot { throw DraftError.notFound }
  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await store.discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }
  func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote {
    throw DraftError.notFound
  }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    if case .confirmNewCreation(let id, let generation) = action {
      return .review(
        try await store.confirmNewCreation(
          id: id, accountID: accountID, expectedGeneration: generation))
    }
    if case .discardUncertainCreation(let id, let generation) = action {
      try await store.discardUncertainCreation(
        id: id, accountID: accountID, expectedGeneration: generation)
      return .discardedDraft(id)
    }
    if case .inspectRemote(let id, let generation) = action {
      inspectionGenerations.append(generation)
      if pausesInspection {
        pausesInspection = false
        await withCheckedContinuation {
          inspectionGate = $0
          inspectionObserver?.resume()
          inspectionObserver = nil
        }
      }
      if !inspectionFailures.isEmpty { throw inspectionFailures.removeFirst() }
      if returnsDraftInsteadOfReview { return .draft(try await snapshot()) }
      return .review(
        try await store.inspectRemoteChange(
          id: id, accountID: accountID, expectedGeneration: generation,
          remote: remoteContent, revision: "remote"))
    }
    throw DraftError.notFound
  }

  func failNextInspection(with error: any Error) { inspectionFailures.append(error) }
  func returnDraftInsteadOfReview() { returnsDraftInsteadOfReview = true }
  func holdNextInspection() { pausesInspection = true }
  func waitForInspection() async {
    if inspectionGate != nil { return }
    await withCheckedContinuation { inspectionObserver = $0 }
  }
  func releaseInspection() {
    inspectionGate?.resume()
    inspectionGate = nil
  }
  func failNextRefresh(with error: any Error) { refreshFailures.append(error) }
  func holdNextRefresh() { pausesRefresh = true }
  func waitForRefresh() async {
    if refreshGate != nil { return }
    await withCheckedContinuation { refreshObserver = $0 }
  }
  func releaseRefresh() {
    refreshGate?.resume()
    refreshGate = nil
  }
  func setRemoteContent(_ content: String?) { remoteContent = content }

  func persist(
    draftID: UUID, accountID: UUID, text: String, generation: UInt64
  ) async throws -> DraftSnapshot {
    if persistenceFails { throw URLError(.cannotWriteToFile) }
    persistedGenerations.append(generation)
    return try await store.persist(
      id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) async throws -> DraftSnapshot {
    if pausesBeforeValidation {
      pausesBeforeValidation = false
      await pausePublication()
    }
    if reason != .manual, !(await shouldPublish()) { throw CancellationError() }
    publishCount += 1
    publicationReasons.append(reason)
    if publicationRejected { throw DraftError.readOnly }
    if let publicationFailure {
      try await store.setState(publicationFailure, id: draftID, accountID: accountID)
      throw URLError(.timedOut)
    }
    let sent = try await snapshot()
    try await store.beginAttempt(
      id: draftID, accountID: accountID, content: sent.text,
      generation: sent.generation, remote: sent.baseContent)
    if reason == .manual {
      await pausePublication()
    }
    return try await store.acknowledge(
      id: draftID, accountID: accountID, gistID: "synthetic",
      content: sent.text, revision: "2", generation: sent.generation)
  }

  private func pausePublication() async {
    await withCheckedContinuation {
      publishing = $0
      publishObserver?.resume()
      publishObserver = nil
    }
  }

  func holdBeforeValidation() { pausesBeforeValidation = true }

  func snapshot() async throws -> DraftSnapshot {
    try await store.draft(id: id, accountID: accountID)
  }

  func waitForPublish() async {
    if publishing != nil { return }
    await withCheckedContinuation { publishObserver = $0 }
  }

  func releasePublish() {
    publishing?.resume()
    publishing = nil
  }

  func failPersistence() { persistenceFails = true }
  func rejectPublication() { publicationRejected = true }
  func failPublication(with state: SaveState) { publicationFailure = state }
  func introduceConflict(remote: String?) async throws -> DraftSnapshot {
    let current = try await snapshot()
    try await store.setState(
      .conflict(
        .init(
          generation: current.generation, base: current.baseContent, local: current.text,
          remote: remote, remoteRevision: "2", suggestedMerge: nil)), id: id, accountID: accountID)
    return try await snapshot()
  }
}

private struct ProviderReadFailure: CustomNSError {
  static let errorDomain = "GistPadTests.ProviderReadFailure"
  let underlying: any Error
  var errorCode: Int { 1 }
  var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying] }
}
