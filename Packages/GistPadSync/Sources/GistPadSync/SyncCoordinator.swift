import Foundation

public enum PublishReason: Equatable, Sendable {
    case manual
    case autosave
    case background
    case leaving
}

public actor SyncCoordinator {
    private let client: GitHubClient
    private let store: DraftStore
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var notBefore: Date = .distantPast

    public init(client: GitHubClient, store: DraftStore) {
        self.client = client
        self.store = store
    }

    @discardableResult
    public func publish(
        id: UUID, accountID: UUID, reason: PublishReason = .manual,
        autosaveEnabled: Bool = true, expectedGeneration: UInt64? = nil,
        shouldPublish: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> DraftSnapshot {
        if reason == .autosave, !autosaveEnabled {
            return try await store.draft(id: id, accountID: accountID)
        }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var draft = try await store.draft(id: id, accountID: accountID)
        if case .conflict = draft.state, !isCleanDraft(draft) { return draft }
        try await validatePublication(
            draft, reason: reason, expectedGeneration: expectedGeneration,
            shouldPublish: shouldPublish)
        if reason != .autosave, draft.autosavePaused {
            draft = try await store.resumeAutosave(id: id, accountID: accountID)
        }
        if draft.gistID == nil, draft.attemptedGeneration != nil {
            try await store.setState(.failed(.creationUncertain), id: id, accountID: accountID)
            throw DraftError.ambiguousCreation
        }
        do {
            if Date.now < notBefore { try await Task.sleep(for: .seconds(notBefore.timeIntervalSinceNow)) }
            if let gistID = draft.gistID {
                let fetched = try await client.remoteFile(
                    gistID: gistID, ownerID: draft.githubUserID, filename: draft.filename)
                let remoteGist = fetched.gist
                let remote = fetched.content
                try await validatePublication(
                    draft, reason: reason, expectedGeneration: expectedGeneration,
                    shouldPublish: shouldPublish)
                if let attempted = draft.attemptedContent, let generation = draft.attemptedGeneration {
                    if sourceEqual(remote, attempted) {
                        draft = try await store.acknowledge(
                            id: id, accountID: accountID, gistID: gistID, content: attempted,
                            revision: remoteGist.revision, generation: generation, publishedGist: remoteGist
                        )
                        if case .savedToGitHub = draft.state { return draft }
                    } else {
                        try await store.clearAttempt(id: id, accountID: accountID)
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
                        content: remote, revision: remoteGist.revision
                    ).snapshot
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
            try await validatePublication(
                draft, reason: reason, expectedGeneration: expectedGeneration,
                shouldPublish: shouldPublish)
            try await store.beginAttempt(
                id: id, accountID: accountID, content: draft.text,
                generation: draft.generation
            )
            let result: Gist
            if let gistID = draft.gistID {
                result = try await client.updateGist(
                    id: gistID, files: [draft.filename: .content(draft.text)]
                )
            } else {
                result = try await client.createGist(
                    description: draft.description, filename: draft.filename,
                    content: GistConventions.encodeContent(draft.text)
                )
            }
            let acknowledged = try await client.content(gist: result, filename: draft.filename)
            guard sourceEqual(acknowledged, draft.text) else { throw DraftError.remoteDidNotAcknowledge }
            return try await store.acknowledge(
                id: id, accountID: accountID, gistID: draft.gistID ?? result.id, content: acknowledged,
                revision: result.revision, generation: draft.generation, publishedGist: result
            )
        } catch {
            let latest = try await store.draft(id: id, accountID: accountID)
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                if latest.attemptedGeneration != nil {
                    try await store.setState(
                        .failed(latest.gistID == nil ? .creationUncertain : .publicationUncertain),
                        id: id, accountID: accountID)
                }
                throw CancellationError()
            }
            let state: PublishState
            if latest.gistID == nil, latest.attemptedGeneration != nil {
                state = .failed(.creationUncertain)
            } else if let error = error as? GitHubClientError {
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

    private func validatePublication(
        _ draft: DraftSnapshot, reason: PublishReason, expectedGeneration: UInt64?,
        shouldPublish: @escaping @Sendable () async -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard reason != .manual else { return }
        guard reason != .autosave || !draft.autosavePaused,
              expectedGeneration == nil || draft.generation == expectedGeneration,
              await shouldPublish() else { throw CancellationError() }
        let latest = try await store.draft(id: draft.id, accountID: draft.accountID)
        guard latest.generation == draft.generation,
              reason != .autosave || !latest.autosavePaused,
              latest.attemptedGeneration == nil else { throw CancellationError() }
        if case .conflict = latest.state, !isCleanDraft(latest) { throw CancellationError() }
    }

    public func adoptRemoteIfClean(id: UUID, accountID: UUID) async throws -> DraftSnapshot {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let draft = try await store.draft(id: id, accountID: accountID)
        guard isCleanDraft(draft), let gistID = draft.gistID else { return draft }
        let remote = try await client.remoteFile(
            gistID: gistID, ownerID: draft.githubUserID, filename: draft.filename)
        guard let content = remote.content else { return draft }
        return try await store.refreshCleanDraft(
            id: id, accountID: accountID, expectedGeneration: draft.generation,
            content: content, revision: remote.gist.revision
        ).snapshot
    }

    private func isCleanDraft(_ draft: DraftSnapshot) -> Bool {
        draft.attemptedContent == nil && draft.attemptedGeneration == nil
            && sourceEqual(draft.text, draft.baseContent)
    }

    func adoptDailyCreation(id: UUID, accountID: UUID, createdGistID: String) async throws -> DraftSnapshot {
        await acquire()
        defer { release() }
        let draft = try await store.draft(id: id, accountID: accountID)
        if draft.gistID == createdGistID { return draft }
        guard draft.gistID == nil else { throw DraftError.ambiguousCreation }
        let attempted = draft.attemptedContent ?? draft.text
        let generation = draft.attemptedGeneration ?? draft.generation
        let remote = try await client.remoteFile(
            gistID: createdGistID, ownerID: draft.githubUserID, filename: draft.filename)
        let gist = remote.gist
        guard let content = remote.content else { throw GitHubClientError.missingFile }
        guard sourceEqual(content, attempted) else { throw DraftError.remoteDidNotAcknowledge }
        return try await store.acknowledge(
            id: id, accountID: accountID, gistID: gist.id,
            content: content, revision: gist.revision, generation: generation, publishedGist: gist
        )
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
