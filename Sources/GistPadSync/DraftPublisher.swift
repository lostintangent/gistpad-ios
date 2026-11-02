import Foundation

public enum PublishReason: Equatable, Sendable {
    case manual
    case autosave
    case background
    case leaving
}

public actor DraftPublisher {
    private let client: GitHubClient
    private let store: DraftStore
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var notBefore: Date = .distantPast

    public init(client: GitHubClient, store: DraftStore) {
        self.client = client
        self.store = store
    }

    /// Publishes the draft. Autosave and lifecycle publishes are checked once before reaching GitHub,
    /// and typing during the publish hands over to the publish that typing schedules.
    @discardableResult
    public func publish(
        id: UUID, accountID: UUID, reason: PublishReason = .manual, expectedGeneration: UInt64? = nil,
        shouldPublish: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> Draft {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var draft = try await store.draft(id: id, accountID: accountID)
        if case .conflict = draft.state, !isCleanDraft(draft) { return draft }
        if reason != .manual {
            guard expectedGeneration == nil || draft.generation == expectedGeneration,
                  await shouldPublish() else { throw CancellationError() }
        }
        do {
            if Date.now < notBefore { try await Task.sleep(for: .seconds(notBefore.timeIntervalSinceNow)) }
            if draft.gistID == nil, let attempted = draft.attemptedContent,
               let generation = draft.attemptedGeneration {
                if let created = try await createdGist(for: draft, content: attempted) {
                    draft = try await store.acknowledge(
                        id: id, accountID: accountID, gistID: created.id, content: attempted,
                        revision: created.revision, generation: generation, publishedGist: created)
                    if case .savedToGitHub = draft.state { return draft }
                } else {
                    draft = try await store.clearAttempt(id: id, accountID: accountID)
                }
            }
            if let gistID = draft.gistID {
                let fetched = try await client.remoteFile(
                    gistID: gistID, ownerID: draft.githubUserID, filename: draft.filename)
                let remoteGist = fetched.gist
                let remote = fetched.content
                if let attempted = draft.attemptedContent, let generation = draft.attemptedGeneration {
                    if sourceEqual(remote, attempted) {
                        draft = try await store.acknowledge(
                            id: id, accountID: accountID, gistID: gistID, content: attempted,
                            revision: remoteGist.revision, generation: generation, publishedGist: remoteGist
                        )
                        if case .savedToGitHub = draft.state { return draft }
                    } else {
                        draft = try await store.clearAttempt(id: id, accountID: accountID)
                    }
                }
                if sourceEqual(remote, draft.text) {
                    return try await store.acknowledge(
                        id: id, accountID: accountID, gistID: gistID, content: draft.text,
                        revision: remoteGist.revision, generation: draft.generation, publishedGist: remoteGist
                    )
                }
                if isCleanDraft(draft), let remote {
                    return try await store.refreshCleanDraft(
                        id: id, accountID: accountID, expectedGeneration: draft.generation,
                        content: remote, revision: remoteGist.revision)
                }
                guard sourceEqual(remote, draft.baseContent) else {
                    let conflict = DraftConflict(
                        generation: draft.generation, base: draft.baseContent, local: draft.text,
                        remote: remote, remoteRevision: remoteGist.revision
                    )
                    try await store.setState(.conflict(conflict), id: id, accountID: accountID)
                    return try await store.draft(id: id, accountID: accountID)
                }
            }
            try await store.beginAttempt(
                id: id, accountID: accountID, content: draft.text, generation: draft.generation)
            let result: Gist
            if let gistID = draft.gistID {
                result = try await client.updateGist(
                    id: gistID, files: [draft.filename: .content(draft.text)]
                )
            } else {
                result = try await client.createGist(
                    description: draft.description, filename: draft.filename,
                    content: GistFile.encodeContent(draft.text)
                )
            }
            let acknowledged = try await client.content(gist: result, filename: draft.filename)
            guard sourceEqual(acknowledged, draft.text) else { throw DraftError.remoteDidNotAcknowledge }
            return try await store.acknowledge(
                id: id, accountID: accountID, gistID: draft.gistID ?? result.id, content: acknowledged,
                revision: result.revision, generation: draft.generation, publishedGist: result
            )
        } catch {
            // A publish that was sent stays recorded, and the next publish checks GitHub for it first.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                if case .savingToGitHub = try await store.draft(id: id, accountID: accountID).state {
                    try await store.setState(.savedLocally, id: id, accountID: accountID)
                }
                throw CancellationError()
            }
            let state: PublishState
            if let error = error as? GitHubClientError {
                switch error {
                case .http(let status, let retryAfter):
                    if let retryAfter { notBefore = max(notBefore, retryAfter) }
                    state = status == 401 ? .reconnect : .failed(.http(status: status, retryAfter: retryAfter))
                case .incompleteGist, .fileTooLarge: state = .failed(.incompleteRemote)
                default: state = .failed(.network)
                }
            } else if error is AccountError {
                state = .reconnect
            } else if (error as? DraftError) == .readOnly {
                state = .failed(.readOnly)
            } else {
                state = .failed(.network)
            }
            try await store.setState(state, id: id, accountID: accountID)
            throw error
        }
    }

    /// Reads GitHub's copy of the file once. A clean draft takes it on, and edits on both sides become
    /// a conflict that shows the diff.
    public func inspect(id: UUID, accountID: UUID) async throws -> Draft {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let draft = try await store.draft(id: id, accountID: accountID)
        guard let gistID = draft.gistID else { return draft }
        if case .conflict = draft.state { return draft }
        let remote = try await client.remoteFile(
            gistID: gistID, ownerID: draft.githubUserID, filename: draft.filename)
        return try await store.inspectRemoteChange(
            id: id, accountID: accountID, expectedGeneration: draft.generation,
            remote: remote.content, revision: remote.gist.revision)
    }

    /// The gist a cut-off create made, found by its description and a same-named file with the same
    /// bytes, so a create is never posted twice.
    private func createdGist(for draft: Draft, content: String) async throws -> Gist? {
        let size = GistFile.encodeContent(content).utf8.count
        for gist in try await client.listGists()
        where (gist.description ?? "") == draft.description && gist.files[draft.filename]?.size == size {
            let remote = try await client.remoteFile(
                gistID: gist.id, ownerID: draft.githubUserID, filename: draft.filename)
            if sourceEqual(remote.content, content) { return remote.gist }
        }
        return nil
    }

    private func isCleanDraft(_ draft: Draft) -> Bool {
        draft.attemptedContent == nil && draft.attemptedGeneration == nil
            && sourceEqual(draft.text, draft.baseContent)
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
