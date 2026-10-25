import Foundation
import Testing
@testable import GistPadComments

@Suite(.serialized) @MainActor
struct CommentConversationTests {
    @Test func preservesKnownTotalsAndThreadsDuringFailedRefresh() async {
        let (controller, remote, _) = make(comments: [comment(1), comment(2, body: "> [comment:1]\n\nReply")])
        await controller.load()
        #expect(controller.knownTotal == 2)
        #expect(controller.threads.count == 1)
        await remote.failReads(.network)
        await controller.refresh()
        #expect(controller.comments?.count == 2)
        #expect(controller.knownTotal == 2)
        #expect(controller.loadFailure == .remote(.network))
        #expect(!controller.composer.canPost)
    }

    @Test func aSuccessfulRefreshClearsAStaleAuthenticationFailureWithoutPosting() async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("Keep this draft after reconnecting")
        await remote.behave(.reject(.authentication))
        await controller.post()
        #expect(controller.mutation == .failed(.remote(.authentication)))
        #expect(!controller.composer.canPost)
        await controller.refresh()
        #expect(controller.mutation == .idle)
        #expect(controller.loadFailure == nil)
        #expect(controller.activeDraft.text == "Keep this draft after reconnecting")
        #expect(controller.composer.canPost)
        #expect(await remote.createCount == 1)
    }

    @Test func aNewOfflineConversationIsUnknownNotEmptyAndRestoresItsDraft() async {
        let (controller, remote, store) = make()
        await controller.prepare()
        controller.updateText("Kept on this device")
        #expect(await controller.flushDraft())
        let restored = make(remote: remote, store: store, scope: controller.scope).0
        await remote.failReads(.network)
        await restored.load()
        #expect(restored.comments == nil)
        #expect(restored.knownTotal == nil)
        #expect(restored.activeDraft.text == "Kept on this device")
        #expect(restored.composer.saveState == .saved)
        #expect(restored.composer.canEdit)
        #expect(!restored.composer.canPost)
    }

    @Test func restoresExactCapturedQuoteAndSeparateReplyDrafts() async {
        let (controller, remote, store) = make(comments: [comment(1)])
        await controller.load()
        let quote = CapturedCommentQuote(filename: "Notes.md", text: "Cafe\u{301}\nsecond line")
        controller.beginQuote(quote)
        controller.updateText("Quote draft")
        controller.beginReply(to: 1)
        controller.updateText("Reply draft")
        #expect(await controller.flushDraft())
        let restored = make(remote: remote, store: store, scope: controller.scope).0
        await restored.load()
        #expect(restored.activeDraft.target == .reply(commentID: 1))
        #expect(restored.activeDraft.text == "Reply draft")
        restored.beginQuote(quote)
        #expect(restored.activeDraft.text == "Quote draft")
        guard case .quote(let captured) = restored.activeDraft.target else {
            Issue.record("The quote context was not restored.")
            return
        }
        #expect(captured.filename == "Notes.md")
        #expect(captured.text.utf8.elementsEqual(quote.text.utf8))
    }

    @Test func missingReplyTargetNeverBecomesARootPost() async {
        let (controller, remote, _) = make(comments: [comment(1)])
        await controller.load()
        controller.beginReply(to: 1)
        controller.updateText("Unsent reply")
        await remote.replace([])
        await controller.post()
        #expect(await remote.createCount == 0)
        #expect(controller.composer.problem == .missingTarget(1))
        #expect(controller.activeDraft.text == "Unsent reply")
    }

    @Test func disallowsRepliesAtTheDeepestSupportedLevel() async {
        let (controller, _, _) = make(comments: [
            comment(1), comment(2, body: "> [comment:1]\n\nOne"),
            comment(3, body: "> [comment:2]\n\nTwo"),
        ])
        await controller.load()
        controller.beginReply(to: 3)
        #expect(controller.composer.problem == .replyDepthLimit)
        #expect(controller.activeDraft.target == .root)
    }

    @Test func editingPreservesTheExactHiddenPrefix() async {
        let original = "> first line\n\n\nOriginal"
        let (controller, remote, _) = make(comments: [comment(1, body: original)])
        await controller.load()
        controller.beginEditing(1)
        controller.updateText("Revised **Markdown**")
        await controller.post()
        let posted = await remote.values
        #expect(posted[0].body == GistCommentBody(original).prefix + "Revised **Markdown**")
        #expect(await remote.updateCount == 1)
        #expect(controller.mutation == .idle)
    }

    @Test func aChangedRemoteCommentDoesNotOverwriteTheNewerBody() async {
        let (controller, remote, _) = make(comments: [comment(1, body: "Original")])
        await controller.load()
        controller.beginEditing(1)
        controller.updateText("Local edit")
        await remote.replace([comment(1, body: "Someone changed this")])
        await controller.post()
        #expect(await remote.updateCount == 0)
        #expect(controller.composer.problem == .commentChanged)
        #expect(controller.activeDraft.text == "Local edit")
        await controller.refresh()
        #expect(controller.mutation == .idle)
        #expect(controller.composer.problem == .commentChanged)
        #expect(controller.activeDraft.text == "Local edit")
        #expect(!controller.composer.canPost)
    }

    @Test func explicitlyRestartingAnEditReplacesItsSnapshotWithoutLosingTypedText() async {
        let (controller, remote, store) = make(comments: [comment(1, body: "> Original quote\n\nOriginal")])
        await controller.load()
        controller.beginEditing(1)
        controller.updateText("Keep this local edit")
        await remote.replace([comment(1, body: "> Changed quote\n\nChanged remotely")])
        await controller.post()
        #expect(controller.composer.problem == .commentChanged)
        #expect(controller.mutation == .failed(.commentChanged))
        controller.beginEditing(1)
        #expect(controller.composer.problem == .commentChanged)
        controller.restartEditing(1)
        #expect(controller.activeDraft.text == "Keep this local edit")
        #expect(controller.composer.problem == nil)
        #expect(controller.mutation == .idle)
        #expect(controller.composer.canPost)
        #expect(await controller.flushDraft())
        let restored = make(remote: remote, store: store, scope: controller.scope).0
        await restored.load()
        #expect(restored.activeDraft.id == controller.activeDraft.id)
        #expect(restored.activeDraft.text == "Keep this local edit")
        #expect(restored.composer.canPost)
        await restored.post()
        #expect(await remote.values.first?.body == "> Changed quote\n\nKeep this local edit")
        #expect(await remote.updateCount == 1)
    }

    @Test(arguments: [(Int64(0), Int64(7)), (Int64(1), Int64(7)), (Int64(2), Int64(8))])
    func anInvalidCreateReceiptCannotClearTheDraft(id: Int64, authorID: Int64) async {
        let (controller, remote, _) = make(comments: [comment(1, body: "Keep this draft")])
        await controller.load()
        controller.updateText("Keep this draft")
        await remote.behave(.malformedCreateReceipt(comment(id, body: "Keep this draft", authorID: authorID)))
        await controller.post()
        #expect(controller.activeDraft.text == "Keep this draft")
        #expect(controller.mutation == .failed(.unconfirmedMutation))
        #expect(controller.knownTotal == 1)
        #expect(controller.composer.canPost)
        #expect(await remote.createCount == 1)
    }

    @Test func gistOwnershipAllowsDeleteButNotEditingAnotherAuthorsComment() async {
        let foreign = comment(1, authorID: 8)
        let (controller, remote, _) = make(comments: [foreign], gistOwnerID: 7)
        await controller.load()
        #expect(!controller.canEdit(foreign))
        #expect(controller.canDelete(foreign))
        controller.beginEditing(1)
        #expect(controller.composer.problem == .notAllowed)
        await controller.delete(1)
        #expect(await remote.deleteCount == 1)
        #expect(controller.knownTotal == 0)
    }

    @Test func deletingAParentRetainsItsRepliesAndTheGistWideTotal() async {
        let (controller, _, _) = make(comments: [
            comment(1), comment(2, body: "> [comment:1]\n\nSurviving reply"),
        ])
        await controller.load()
        await controller.delete(1)
        #expect(controller.comments?.map(\.id) == [2])
        #expect(controller.threads.map(\.id) == [2])
        #expect(controller.knownTotal == 1)
    }

    @Test func aFailedLocalDraftWriteBlocksTheRemoteMutation() async {
        let (controller, remote, store) = make()
        await controller.load()
        controller.updateText("Do not lose me")
        await store.setFailSaves(true)
        await controller.post()
        #expect(await remote.createCount == 0)
        #expect(controller.composer.saveState == .failed)
        #expect(controller.activeDraft.text == "Do not lose me")
        await store.setFailSaves(false)
        #expect(await controller.flushDraft())
        #expect(controller.composer.saveState == .saved)
        #expect(controller.composer.problem == nil)
    }

    @Test func aRejectedPostKeepsItsDraftAndCanBeRetriedExplicitly() async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("Keep after rejection")
        await remote.behave(.reject(.http(status: 422, retryAfter: nil)))
        await controller.post()
        #expect(controller.pendingMutation == nil)
        #expect(controller.activeDraft.text == "Keep after rejection")
        #expect(controller.composer.canPost)
        await remote.behave(.success)
        await controller.post()
        #expect(await remote.createCount == 2)
        #expect(controller.activeDraft.text.isEmpty)
        #expect(controller.knownTotal == 1)
    }

    @Test func aLostAcknowledgementRefreshesAndNeverPostsTwice() async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("Posted once")
        await remote.behave(.applyThenFail)
        await controller.post()
        #expect(await remote.createCount == 1)
        #expect(controller.mutation == .idle)
        #expect(controller.activeDraft.text.isEmpty)
        #expect(controller.pendingMutation == nil)
        #expect(controller.knownTotal == 1)
    }

    @Test func anUnconfirmedPostRefreshesAndLeavesPostForTheUser() async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("Still a draft")
        await remote.behave(.failWithoutApplying)
        await controller.post()
        #expect(await remote.createCount == 1)
        #expect(controller.mutation == .failed(.unconfirmedMutation))
        #expect(controller.activeDraft.text == "Still a draft")
        #expect(controller.pendingMutation == nil)
        #expect(controller.composer.canPost)
    }

    @Test func anInterruptedUncertainPostIsReconciledAfterRestart() async {
        let (controller, remote, store) = make()
        await controller.load()
        controller.updateText("Survive the restart")
        await remote.behave(.applyThenFailAndLoseReads)
        await controller.post()
        #expect(controller.mutation == .needsRefresh)
        #expect(controller.pendingMutation != nil)
        let restored = make(remote: remote, store: store, scope: controller.scope).0
        await remote.failReads(nil)
        await restored.load()
        #expect(await remote.createCount == 1)
        #expect(restored.activeDraft.text.isEmpty)
        #expect(restored.pendingMutation == nil)
        #expect(restored.knownTotal == 1)
    }

    @Test func anOldIdenticalCommentDoesNotAcknowledgeANewUncertainPost() async {
        let (controller, remote, _) = make(comments: [comment(1, body: "Same words")])
        await controller.load()
        controller.updateText("Same words")
        await remote.behave(.failWithoutApplying)
        await controller.post()
        #expect(controller.activeDraft.text == "Same words")
        #expect(controller.mutation == .failed(.unconfirmedMutation))
        #expect(controller.knownTotal == 1)
    }

    @Test(arguments: [false, true])
    func reconciliationRequiresTheAuthorAndExactSourceBytes(canonicalOnly: Bool) async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("Cafe\u{301}")
        await remote.behave(.applyThenFailAndLoseReads)
        await controller.post()
        await remote.replace([
            comment(1, body: canonicalOnly ? "Caf\u{e9}" : "Cafe\u{301}", authorID: canonicalOnly ? 7 : 8),
        ])
        await remote.failReads(nil)
        await controller.refresh()
        #expect(controller.activeDraft.text.utf8.elementsEqual("Cafe\u{301}".utf8))
        #expect(controller.mutation == .failed(.unconfirmedMutation))
        #expect(await remote.createCount == 1)
    }

    @Test func acknowledgedPostWithLocalFailureOnlyRetriesLocalCompletion() async {
        let (controller, remote, store) = make()
        await controller.load()
        controller.updateText("GitHub accepted this")
        await remote.failLocalAfterCreate(store)
        await controller.post()
        #expect(controller.mutation == .localCompletionFailed)
        #expect(controller.activeDraft.text == "GitHub accepted this")
        #expect(controller.knownTotal == 1)
        #expect(!controller.composer.canPost)
        await store.setFailSaves(false)
        await controller.retryLocalCompletion()
        #expect(await remote.createCount == 1)
        #expect(controller.activeDraft.text.isEmpty)
        #expect(controller.mutation == .idle)
    }

    @Test func uncertainEditAcknowledgesItsIDAndRebasesNewerDraftText() async {
        let (controller, remote, _) = make(comments: [comment(1, body: "Original")])
        await controller.load()
        controller.beginEditing(1)
        controller.updateText("First edit")
        await remote.behave(.applyThenFailAndLoseReads)
        await controller.post()
        #expect(controller.mutation == .needsRefresh)
        controller.updateText("Newer edit kept locally")
        await remote.failReads(nil)
        await controller.refresh()
        #expect(controller.activeDraft.text == "Newer edit kept locally")
        #expect(controller.activeDraft.target == .edit(commentID: 1, originalBody: "First edit"))
        #expect(controller.composer.canPost)
        await remote.behave(.success)
        await controller.post()
        #expect(await remote.updateCount == 2)
        #expect(await remote.values.first?.body == "Newer edit kept locally")
    }

    @Test func uncertainDeletionIsAcknowledgedWithoutDeletingAgain() async {
        let (controller, remote, _) = make(comments: [
            comment(1), comment(2, body: "> [comment:1]\n\nA reply"),
        ])
        await controller.load()
        await remote.behave(.applyThenFail)
        await controller.delete(1)
        #expect(await remote.deleteCount == 1)
        #expect(controller.pendingMutation == nil)
        #expect(controller.threads.map(\.id) == [2])
        #expect(controller.knownTotal == 1)
    }

    @Test func flushIncludesTypingThatArrivesDuringAnOlderSave() async {
        let (controller, _, store) = make()
        await controller.prepare()
        controller.updateText("First checkpoint")
        await store.suspendNextSave()
        let flushing = Task { await controller.flushDraft() }
        await store.waitForSave()
        controller.updateText("Newest checkpoint")
        await store.resumeSave()
        #expect(await flushing.value)
        let saved = await store.loadDrafts(scope: controller.scope)
        #expect(saved?.drafts.first?.text == "Newest checkpoint")
        #expect(controller.composer.saveState == .saved)
    }

    @Test func sendingDisablesComposerEditingAndOverlappingPosts() async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("One operation")
        await remote.suspendPosts()
        let sending = Task { await controller.post() }
        await remote.waitForPost()
        #expect(!controller.composer.canEdit)
        controller.updateText("Should not replace the disabled field")
        await controller.post()
        #expect(controller.activeDraft.text == "One operation")
        #expect(await remote.createCount == 1)
        await remote.resumePost()
        await sending.value
        #expect(controller.activeDraft.text.isEmpty)
    }

    @Test func serverRetryDeadlinesPreventAnotherRequest() async {
        let (controller, remote, _) = make()
        await controller.load()
        controller.updateText("Wait for GitHub")
        let deadline = Date.now.addingTimeInterval(3_600)
        await remote.behave(.reject(.http(status: 429, retryAfter: deadline)))
        await controller.post()
        await controller.post()
        await controller.refresh()
        #expect(await remote.createCount == 1)
        #expect(controller.retryAfter == deadline)
        #expect(!controller.composer.canPost)
    }

    @Test func removingQuoteContextDoesNotOverwriteAnotherRootDraft() async {
        let (controller, _, _) = make()
        await controller.load()
        controller.updateText("Root draft")
        controller.beginQuote(.init(filename: "Note.md", text: "A passage"))
        controller.updateText("Quoted draft")
        controller.removeComposerContext()
        #expect(controller.composer.problem == .existingRootDraft)
        #expect(controller.drafts.map(\.text).contains("Root draft"))
        #expect(controller.activeDraft.text == "Quoted draft")
    }

    private func make(
        comments: [GistComment] = [], gistOwnerID: Int64 = 99,
        remote: ConversationRemoteFake? = nil, store: ConversationStoreFake? = nil,
        scope: CommentConversationScope? = nil
    ) -> (CommentConversationController, ConversationRemoteFake, ConversationStoreFake) {
        let remote = remote ?? ConversationRemoteFake(values: comments)
        let store = store ?? ConversationStoreFake()
        let controller = CommentConversationController(
            scope: scope ?? .init(accountID: UUID(), gistID: "abc123"),
            userID: 7, gistOwnerID: gistOwnerID, remote: remote, store: store)
        return (controller, remote, store)
    }

    private func comment(_ id: Int64, body: String = "A comment", authorID: Int64 = 7) -> GistComment {
        GistComment(
            id: id, body: body, user: .init(id: authorID, login: "author"),
            createdAt: Date(timeIntervalSince1970: Double(id)), updatedAt: .distantPast)
    }
}

private actor ConversationStoreFake: CommentConversationStore {
    private var archives: [CommentConversationScope: CommentDraftArchive] = [:]
    private var failSaves = false
    private var shouldSuspend = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func setFailSaves(_ value: Bool) { failSaves = value }
    func suspendNextSave() { shouldSuspend = true }
    func waitForSave() async {
        if saveContinuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumeSave() { saveContinuation?.resume(); saveContinuation = nil }
    func loadDrafts(scope: CommentConversationScope) -> CommentDraftArchive? { archives[scope] }
    func saveDrafts(_ archive: CommentDraftArchive) async throws {
        if shouldSuspend {
            shouldSuspend = false
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { saveContinuation = $0 }
        }
        if failSaves { throw CommentStoreFailure.unavailable }
        if let saved = archives[archive.scope], saved.revision > archive.revision {
            throw CommentStoreFailure.staleWrite
        }
        archives[archive.scope] = archive
    }
}

private actor ConversationRemoteFake: CommentConversationRemote {
    enum Behavior: Sendable {
        case success, applyThenFail, failWithoutApplying, applyThenFailAndLoseReads
        case reject(CommentRemoteFailure)
        case malformedCreateReceipt(GistComment)
    }
    private(set) var values: [GistComment]
    private(set) var createCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0
    private var behavior: Behavior = .success
    private var readFailure: CommentRemoteFailure?
    private var shouldSuspend = false
    private var postContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var storeToFail: ConversationStoreFake?

    init(values: [GistComment]) { self.values = values }
    func replace(_ values: [GistComment]) { self.values = values }
    func failReads(_ failure: CommentRemoteFailure?) { readFailure = failure }
    func behave(_ behavior: Behavior) { self.behavior = behavior }
    func suspendPosts() { shouldSuspend = true }
    func failLocalAfterCreate(_ store: ConversationStoreFake) { storeToFail = store }
    func waitForPost() async {
        if createCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumePost() { postContinuation?.resume(); postContinuation = nil }

    func listComments(gistID: String) throws(CommentRemoteFailure) -> [GistComment] {
        if let readFailure { throw readFailure }
        return values
    }
    func comment(gistID: String, commentID: Int64) throws(CommentRemoteFailure) -> GistComment {
        guard let found = values.first(where: { $0.id == commentID }) else { throw .notFound }
        return found
    }
    func createComment(gistID: String, body: String) async throws(CommentRemoteFailure) -> GistComment {
        createCount += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if shouldSuspend { await withCheckedContinuation { postContinuation = $0 } }
        switch behavior {
        case .reject(let failure): throw failure
        case .failWithoutApplying: throw .network
        case .malformedCreateReceipt(let receipt): return receipt
        default: break
        }
        let id = (values.map(\.id).max() ?? 0) + 1
        let value = GistComment(
            id: id, body: body, user: .init(id: 7, login: "author"),
            createdAt: .now, updatedAt: .now)
        values.append(value)
        if let storeToFail { await storeToFail.setFailSaves(true) }
        switch behavior {
        case .applyThenFail: throw .network
        case .applyThenFailAndLoseReads:
            readFailure = .network
            throw .network
        default: return value
        }
    }
    func updateComment(
        gistID: String, commentID: Int64, body: String
    ) throws(CommentRemoteFailure) -> GistComment {
        updateCount += 1
        try rejectBeforeApplying()
        guard let index = values.firstIndex(where: { $0.id == commentID }) else { throw .notFound }
        let previous = values[index]
        let edited = GistComment(
            id: previous.id, body: body, user: previous.user,
            createdAt: previous.createdAt, updatedAt: .now)
        values[index] = edited
        try failAfterApplying()
        return edited
    }
    func deleteComment(gistID: String, commentID: Int64) throws(CommentRemoteFailure) {
        deleteCount += 1
        try rejectBeforeApplying()
        values.removeAll { $0.id == commentID }
        try failAfterApplying()
    }

    private func rejectBeforeApplying() throws(CommentRemoteFailure) {
        switch behavior {
        case .reject(let failure): throw failure
        case .failWithoutApplying: throw .network
        default: return
        }
    }

    private func failAfterApplying() throws(CommentRemoteFailure) {
        switch behavior {
        case .applyThenFail: throw .network
        case .applyThenFailAndLoseReads:
            readFailure = .network
            throw .network
        default: return
        }
    }
}
