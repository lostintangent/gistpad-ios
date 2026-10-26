import Foundation
import Observation

@MainActor @Observable
public final class CommentConversationController {
    public let scope: CommentConversationScope
    public let userID: Int64?
    public let gistOwnerID: Int64?
    public private(set) var comments: [GistComment]?
    public private(set) var knownTotal: Int?
    public private(set) var isRefreshing = false
    public private(set) var loadFailure: CommentConversationProblem?
    public private(set) var mutation: CommentMutationState = .idle
    public private(set) var draftSaveState: CommentDraftSaveState = .notSaved
    public private(set) var composerProblem: CommentConversationProblem?
    public private(set) var isPrepared = false
    public private(set) var retryAfter: Date?

    private var archive: CommentDraftArchive
    private var remoteAvailable = false
    private var isDeleted = false
    @ObservationIgnored private let remote: any CommentConversationRemote
    @ObservationIgnored private let store: any CommentConversationStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var lastRemoteFailure: CommentRemoteFailure?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    public init(
        scope: CommentConversationScope, userID: Int64?, gistOwnerID: Int64?,
        knownTotal: Int? = nil, remote: any CommentConversationRemote,
        store: any CommentConversationStore
    ) {
        self.scope = scope
        self.userID = userID
        self.gistOwnerID = gistOwnerID
        self.knownTotal = knownTotal
        self.remote = remote
        self.store = store
        archive = CommentDraftArchive(scope: scope)
    }

    deinit {
        saveTask?.cancel()
        retryTask?.cancel()
    }

    public var threads: [GistCommentThread] { GistCommentThread.build(from: comments ?? []) }
    public var drafts: [CommentComposerDraft] { archive.drafts }
    public var pendingMutation: PendingCommentMutation? { archive.pendingMutation }
    public var activeDraft: CommentComposerDraft {
        archive.drafts.first { $0.id == archive.activeDraftID }!
    }
    public var composer: CommentComposerState {
        CommentComposerState(
            draft: activeDraft, saveState: draftSaveState,
            problem: composerProblem ?? targetProblem(activeDraft.target, in: comments),
            canEdit: isPrepared && mutation != .working,
            canPost: isPrepared && !isRefreshing && mutation != .working && archive.pendingMutation == nil
                && userID != nil && remoteAvailable && draftSaveState != .failed
                && (retryAfter == nil || retryAfter! <= .now)
                && !GistCommentBody.trim(activeDraft.text).isEmpty
                && targetProblem(activeDraft.target, in: comments) == nil)
    }

    public func prepare() async {
        guard !isDeleted else { return }
        if let preparation { await preparation.value; return }
        guard !isPrepared else { return }
        let task = Task { await restore() }
        preparation = task
        await task.value
        preparation = nil
    }

    public func refresh() async {
        await prepare()
        guard !isDeleted, !isRefreshing, mutation != .working else { return }
        guard canRequest else { loadFailure = lastRemoteFailure.map(CommentConversationProblem.remote); return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let loaded = try await remote.listComments(gistID: scope.gistID)
            receive(loaded)
            if archive.pendingMutation != nil {
                mutation = .working
                await reconcile(with: loaded)
            } else if case .failed = mutation {
                mutation = .idle
            }
        } catch {
            failedRemote(error)
            loadFailure = .remote(error)
            if archive.pendingMutation != nil { mutation = .needsRefresh }
        }
    }

    public func beginComment() { select(.root) }

    public func discardAfterGistDeletion() async throws {
        isDeleted = true
        isPrepared = false
        let saving = saveTask
        saving?.cancel()
        saveTask = nil
        retryTask?.cancel()
        await saving?.value
        if let preparation { await preparation.value }
        archive = CommentDraftArchive(scope: scope)
        comments = nil
        knownTotal = nil
        remoteAvailable = false
        mutation = .idle
        composerProblem = nil
        draftSaveState = .notSaved
        try await store.removeDrafts(scope: scope)
    }

    public func beginQuote(_ quote: CapturedCommentQuote) {
        guard CommentQuoteMatcher.isEligibleSelection(quote.text) else {
            composerProblem = .invalidSelection
            return
        }
        select(.quote(quote))
    }

    public func beginReply(to commentID: Int64) { select(.reply(commentID: commentID)) }

    public func beginEditing(_ commentID: Int64) {
        guard let comment = comments?.first(where: { $0.id == commentID }) else {
            composerProblem = .missingTarget(commentID)
            return
        }
        guard comment.canEdit(as: userID) else { composerProblem = .notAllowed; return }
        select(.edit(commentID: commentID, originalBody: comment.body), text: comment.parsedBody.text)
    }

    public func restartEditing(_ commentID: Int64) {
        guard isPrepared, mutation != .working else { composerProblem = .busy; return }
        guard archive.pendingMutation == nil else { composerProblem = .unresolvedMutation; return }
        guard case .edit(let activeID, _) = activeDraft.target, activeID == commentID else {
            composerProblem = .notAllowed
            return
        }
        guard let comment = comments?.first(where: { $0.id == commentID }) else {
            composerProblem = .missingTarget(commentID)
            return
        }
        guard canEdit(comment) else { composerProblem = .notAllowed; return }
        let draft = activeDraft
        let index = archive.drafts.firstIndex { $0.id == draft.id }!
        archive.drafts[index] = CommentComposerDraft(
            id: draft.id, target: .edit(commentID: commentID, originalBody: comment.body),
            text: draft.text, generation: draft.generation + 1)
        composerProblem = nil
        if mutation == .failed(.commentChanged) { mutation = .idle }
        changed()
    }

    public func removeComposerContext() {
        guard case .root = activeDraft.target else {
            let text = activeDraft.text
            if let root = archive.drafts.first(where: { $0.target == .root }),
               !root.text.isEmpty, !Self.sameBytes(root.text, text) {
                composerProblem = .existingRootDraft
                return
            }
            select(.root)
            updateText(text)
            return
        }
    }

    public func updateText(_ text: String) {
        guard isPrepared, mutation != .working else { composerProblem = .busy; return }
        guard !Self.sameBytes(activeDraft.text, text) else { return }
        let index = archive.drafts.firstIndex { $0.id == archive.activeDraftID }!
        archive.drafts[index].text = text
        archive.drafts[index].generation += 1
        changed()
    }

    @discardableResult
    public func flushDraft() async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard isPrepared else { draftSaveState = .failed; return false }
        while true {
            let snapshot = archive
            guard await persist(snapshot) else { return false }
            if snapshot.revision == archive.revision {
                saveTask?.cancel()
                saveTask = nil
                return true
            }
        }
    }

    public func canEdit(_ comment: GistComment) -> Bool { comment.canEdit(as: userID) }
    public func canDelete(_ comment: GistComment) -> Bool {
        comment.canDelete(as: userID, gistOwnerID: gistOwnerID)
    }

    public func post() async {
        guard await startMutation() else { return }
        let draft = activeDraft
        guard !GistCommentBody.trim(draft.text).isEmpty else {
            mutation = .failed(.emptyBody)
            return
        }
        let operation: CommentMutationOperation
        switch draft.target {
        case .root:
            operation = .create(body: draft.text)
        case .quote(let quote):
            operation = .create(body: GistCommentBody.quoting(quote.text, text: draft.text))
        case .reply(let id):
            do {
                operation = .create(body: try GistCommentBody.replying(to: id, text: draft.text))
            } catch {
                composerProblem = .missingTarget(id)
                mutation = .failed(.missingTarget(id))
                return
            }
        case .edit(let id, let original):
            operation = .edit(
                commentID: id, body: GistCommentBody(original).replacingText(with: draft.text),
                originalBody: original)
        }
        do {
            let current = try await remote.listComments(gistID: scope.gistID)
            guard !isDeleted else { return }
            receive(current)
            if let problem = targetProblem(draft.target, in: current) {
                composerProblem = problem
                mutation = .failed(problem)
                return
            }
            await send(PendingCommentMutation(
                operation: operation, draftID: draft.id, draftGeneration: draft.generation,
                baselineIDs: Set(current.map(\.id)), authorID: userID!))
        } catch {
            failedRemote(error)
            mutation = .failed(.remote(error))
        }
    }

    public func delete(_ commentID: Int64) async {
        guard await startMutation() else { return }
        do {
            let current = try await remote.listComments(gistID: scope.gistID)
            guard !isDeleted else { return }
            receive(current)
            guard let comment = current.first(where: { $0.id == commentID }) else {
                mutation = .failed(.missingTarget(commentID))
                return
            }
            guard canDelete(comment) else { mutation = .failed(.notAllowed); return }
            await send(PendingCommentMutation(
                operation: .delete(commentID: commentID), draftID: nil, draftGeneration: nil,
                baselineIDs: Set(current.map(\.id)), authorID: userID!))
        } catch {
            failedRemote(error)
            mutation = .failed(.remote(error))
        }
    }

    public func retryLocalCompletion() async {
        guard archive.pendingMutation?.isAcknowledged == true, !isRefreshing, mutation != .working else {
            composerProblem = .unresolvedMutation
            return
        }
        mutation = .working
        await finishAcknowledgedMutation()
    }

    private func restore() async {
        var restoredDrafts = false
        do {
            if let saved = try await store.loadDrafts(scope: scope) {
                guard !isDeleted else { return }
                guard saved.scope == scope,
                      saved.drafts.contains(where: { $0.id == saved.activeDraftID }),
                      Set(saved.drafts.map(\.id)).count == saved.drafts.count else {
                    throw CommentStoreFailure.invalidRecord
                }
                archive = saved
                draftSaveState = .saved
                if let pending = saved.pendingMutation {
                    mutation = pending.isAcknowledged ? .localCompletionFailed : .needsRefresh
                }
            }
            restoredDrafts = true
        } catch {
            draftSaveState = .failed
            composerProblem = .localStorage
        }
        isPrepared = restoredDrafts && !isDeleted
    }

    private func select(_ target: CommentComposerTarget, text: String = "") {
        guard isPrepared, mutation != .working else { composerProblem = .busy; return }
        guard archive.pendingMutation == nil else {
            composerProblem = .unresolvedMutation
            return
        }
        if let problem = targetProblem(target, in: comments) {
            composerProblem = problem
            return
        }
        if let existing = archive.drafts.first(where: { $0.target.storageKey == target.storageKey }) {
            archive.activeDraftID = existing.id
        } else {
            let draft = CommentComposerDraft(target: target, text: text)
            archive.drafts.append(draft)
            archive.activeDraftID = draft.id
        }
        composerProblem = nil
        changed()
    }

    private func changed() {
        archive.revision += 1
        draftSaveState = .notSaved
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await self.persist(self.archive)
        }
    }

    private func persist(_ snapshot: CommentDraftArchive) async -> Bool {
        guard !isDeleted else { return false }
        draftSaveState = .saving
        do {
            try await store.saveDrafts(snapshot)
            guard !isDeleted else { return false }
            if snapshot.revision >= archive.revision {
                draftSaveState = .saved
                if composerProblem == .localStorage {
                    composerProblem = targetProblem(activeDraft.target, in: comments)
                }
            }
            return true
        } catch CommentStoreFailure.staleWrite {
            if snapshot.revision < archive.revision { return true }
            draftSaveState = .failed
            composerProblem = .localStorage
            return false
        } catch {
            if snapshot.revision >= archive.revision {
                draftSaveState = .failed
                composerProblem = .localStorage
            }
            return false
        }
    }

    private func receive(_ loaded: [GistComment]) {
        guard !isDeleted else { return }
        comments = GistComment.latestVersions(in: loaded)
        knownTotal = comments!.count
        remoteAvailable = true
        loadFailure = nil
        composerProblem = targetProblem(activeDraft.target, in: comments)
    }

    private func targetProblem(
        _ target: CommentComposerTarget, in comments: [GistComment]?
    ) -> CommentConversationProblem? {
        switch target {
        case .root, .quote: return nil
        case .reply(let id):
            guard id > 0 else { return .missingTarget(id) }
            guard let comments else { return .missingTarget(id) }
            guard let thread = findThread(id, in: GistCommentThread.build(from: comments)) else {
                return .missingTarget(id)
            }
            return thread.canReply ? nil : .replyDepthLimit
        case .edit(let id, let original):
            guard id > 0 else { return .missingTarget(id) }
            guard let comment = comments?.first(where: { $0.id == id }) else { return .missingTarget(id) }
            guard comment.canEdit(as: userID) else { return .notAllowed }
            return Self.sameBytes(comment.body, original) ? nil : .commentChanged
        }
    }

    private func findThread(_ id: Int64, in threads: [GistCommentThread]) -> GistCommentThread? {
        for thread in threads {
            if thread.id == id { return thread }
            if let found = findThread(id, in: thread.replies) { return found }
        }
        return nil
    }

    private func startMutation() async -> Bool {
        guard isPrepared, !isRefreshing, mutation != .working else {
            composerProblem = .busy
            return false
        }
        guard archive.pendingMutation == nil else {
            composerProblem = .unresolvedMutation
            return false
        }
        guard userID != nil else { mutation = .failed(.notAllowed); return false }
        guard canRequest else {
            mutation = .failed(.remote(lastRemoteFailure!))
            return false
        }
        mutation = .working
        guard await flushDraft() else { mutation = .failed(.localStorage); return false }
        return true
    }

    private func send(_ pending: PendingCommentMutation) async {
        var next = archive
        next.pendingMutation = pending
        next.revision += 1
        guard await persist(next) else { mutation = .failed(.localStorage); return }
        archive = next
        do throws(CommentRemoteFailure) {
            switch pending.operation {
            case .create(let body):
                let comment = try await remote.createComment(gistID: scope.gistID, body: body)
                guard comment.id > 0, !pending.baselineIDs.contains(comment.id),
                      comment.user?.id == pending.authorID, Self.sameBytes(comment.body, body) else {
                    throw CommentRemoteFailure.invalidResponse
                }
                await acknowledge(comment: comment)
            case .edit(let id, let body, _):
                let comment = try await remote.updateComment(gistID: scope.gistID, commentID: id, body: body)
                guard comment.id == id, Self.sameBytes(comment.body, body) else {
                    throw CommentRemoteFailure.invalidResponse
                }
                await acknowledge(comment: comment)
            case .delete(let id):
                try await remote.deleteComment(gistID: scope.gistID, commentID: id)
                await acknowledge(deleted: true)
            }
        } catch {
            failedRemote(error)
            if error.definitelyRejectedMutation {
                if case .http = error { remoteAvailable = true }
                var rejected = archive
                rejected.pendingMutation = nil
                rejected.revision += 1
                archive = rejected
                _ = await persist(rejected)
                mutation = .failed(.remote(error))
            } else {
                await refreshUncertainMutation()
            }
        }
    }

    private func acknowledge(comment: GistComment? = nil, deleted: Bool = false) async {
        guard !isDeleted else { return }
        if var updated = comments {
            if let comment {
                updated.removeAll { $0.id == comment.id }
                updated.append(comment)
            } else if deleted, case .delete(let id) = archive.pendingMutation?.operation {
                updated.removeAll { $0.id == id }
            }
            receive(updated)
        }
        archive.pendingMutation?.acknowledgedComment = comment
        archive.pendingMutation?.acknowledgedDeletion = deleted
        archive.revision += 1
        guard await persist(archive) else { mutation = .localCompletionFailed; return }
        await finishAcknowledgedMutation()
    }

    private func finishAcknowledgedMutation() async {
        guard let pending = archive.pendingMutation, pending.isAcknowledged else {
            mutation = .failed(.unresolvedMutation)
            return
        }
        var next = archive
        next.pendingMutation = nil
        if let id = pending.draftID,
           let index = next.drafts.firstIndex(where: { $0.id == id }) {
            if next.drafts[index].generation == pending.draftGeneration {
                next.drafts.remove(at: index)
                if next.activeDraftID == id {
                    let root = next.drafts.first(where: { $0.target == .root }) ?? CommentComposerDraft()
                    if !next.drafts.contains(where: { $0.id == root.id }) { next.drafts.append(root) }
                    next.activeDraftID = root.id
                }
            } else if case .edit(let commentID, _) = next.drafts[index].target,
                      let acknowledged = pending.acknowledgedComment {
                let draft = next.drafts[index]
                next.drafts[index] = CommentComposerDraft(
                    id: draft.id,
                    target: .edit(commentID: commentID, originalBody: acknowledged.body),
                    text: draft.text, generation: draft.generation + 1)
            }
        }
        next.revision += 1
        guard await persist(next) else { mutation = .localCompletionFailed; return }
        archive = next
        draftSaveState = .saved
        composerProblem = nil
        mutation = .idle
    }

    private func refreshUncertainMutation() async {
        guard canRequest else {
            mutation = .needsRefresh
            loadFailure = lastRemoteFailure.map(CommentConversationProblem.remote)
            return
        }
        do {
            let current = try await remote.listComments(gistID: scope.gistID)
            receive(current)
            await reconcile(with: current)
        } catch {
            failedRemote(error)
            loadFailure = .remote(error)
            mutation = .needsRefresh
        }
    }

    private func reconcile(with current: [GistComment]) async {
        guard !isDeleted else { return }
        guard let pending = archive.pendingMutation else { mutation = .idle; return }
        if pending.isAcknowledged { await finishAcknowledgedMutation(); return }
        switch pending.operation {
        case .create(let body):
            if let match = current.first(where: {
                !pending.baselineIDs.contains($0.id) && $0.user?.id == pending.authorID
                    && Self.sameBytes($0.body, body)
            }) {
                await acknowledge(comment: match)
                return
            }
        case .edit(let id, let body, _):
            if let match = current.first(where: { $0.id == id && Self.sameBytes($0.body, body) }) {
                await acknowledge(comment: match)
                return
            }
        case .delete(let id):
            if !current.contains(where: { $0.id == id }) {
                await acknowledge(deleted: true)
                return
            }
        }
        var next = archive
        next.pendingMutation = nil
        next.revision += 1
        guard await persist(next) else { mutation = .needsRefresh; return }
        archive = next
        mutation = .failed(.unconfirmedMutation)
    }

    private var canRequest: Bool { retryAfter == nil || retryAfter! <= .now }

    private func failedRemote(_ failure: CommentRemoteFailure) {
        lastRemoteFailure = failure
        retryAfter = failure.retryAfter
        remoteAvailable = false
        retryTask?.cancel()
        if let deadline = retryAfter, deadline > .now {
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow)) }
                catch { return }
                guard let self, self.retryAfter == deadline else { return }
                self.retryAfter = nil
            }
        }
    }

    private static func sameBytes(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }
}
