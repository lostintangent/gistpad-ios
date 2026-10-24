import Foundation

public enum PublishReason: Equatable, Sendable {
    case manual
    case autosave
    case background
}

public actor SyncCoordinator {
    private let client: GitHubClient
    public let store: DraftStore
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var notBefore: Date = .distantPast
    private let mutationInterval: Duration

    public init(client: GitHubClient, store: DraftStore, mutationInterval: Duration = .seconds(1)) {
        self.client = client
        self.store = store
        self.mutationInterval = mutationInterval
    }

    public func cancelScheduledPublishing() {
        for task in scheduled.values { task.cancel() }
        scheduled.removeAll()
    }

    public func scheduleAutosave(
        id: UUID, accountID: UUID, enabled: Bool,
        onResult: @escaping @Sendable (Result<DraftSnapshot, any Error>) async -> Void
    ) {
        scheduled[id]?.cancel()
        scheduled[id] = nil
        guard enabled else { return }
        scheduled[id] = Task {
            do {
                try await Task.sleep(for: .seconds(5))
                let result = try await publish(id: id, accountID: accountID, reason: .autosave)
                await onResult(.success(result))
            } catch is CancellationError {
                return
            } catch {
                await onResult(.failure(error))
            }
        }
    }

    @discardableResult
    public func publish(
        id: UUID, accountID: UUID, reason: PublishReason = .manual,
        autosaveEnabled: Bool = true, expectedGeneration: UInt64? = nil,
        shouldPublish: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> DraftSnapshot {
        if reason != .manual, !autosaveEnabled {
            return try await store.draft(id: id, accountID: accountID)
        }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var draft = try await store.draft(id: id, accountID: accountID)
        if case .conflict = draft.state { return draft }
        try await validatePublication(
            draft, reason: reason, expectedGeneration: expectedGeneration,
            shouldPublish: shouldPublish)
        if reason == .manual, draft.autosavePaused {
            draft = try await store.resumeAutosave(id: id, accountID: accountID)
        }
        if draft.gistID == nil, draft.attemptedGeneration != nil {
            try await store.setState(.failed(.creationUncertain), id: id, accountID: accountID)
            throw DraftError.ambiguousCreation
        }
        do {
            if Date.now < notBefore { try await Task.sleep(for: .seconds(notBefore.timeIntervalSinceNow)) }
            if let gistID = draft.gistID {
                let remoteGist = try await client.gist(id: gistID)
                guard remoteGist.owner?.id == draft.githubUserID else { throw DraftError.readOnly }
                guard remoteGist.truncated != true else { throw GitHubClientError.incompleteGist }
                let remote: String?
                if remoteGist.files[draft.filename] == nil { remote = nil }
                else { remote = try await client.content(gist: remoteGist, filename: draft.filename) }
                try await validatePublication(
                    draft, reason: reason, expectedGeneration: expectedGeneration,
                    shouldPublish: shouldPublish)
                if let attempted = draft.attemptedContent, let generation = draft.attemptedGeneration {
                    if sourceEqual(remote, attempted) {
                        draft = try await store.acknowledge(
                            id: id, accountID: accountID, gistID: gistID, content: attempted,
                            revision: remoteGist.revision, generation: generation
                        )
                        if case .savedToGitHub = draft.state { return draft }
                    } else {
                        try await store.clearAttempt(id: id, accountID: accountID)
                    }
                }
                if sourceEqual(remote, draft.text) {
                    return try await store.acknowledge(
                        id: id, accountID: accountID, gistID: gistID, content: draft.text,
                        revision: remoteGist.revision, generation: draft.generation
                    )
                }
                guard sourceEqual(remote, draft.baseContent) else {
                    let suggestion: String?
                    if let base = draft.baseContent, let remote {
                        suggestion = ThreeWayMerge.merge(base: base, local: draft.text, remote: remote)
                    } else { suggestion = nil }
                    let conflict = DraftConflict(
                        generation: draft.generation, base: draft.baseContent, local: draft.text,
                        remote: remote, remoteRevision: remoteGist.revision, suggestedMerge: suggestion
                    )
                    try await store.setState(.conflict(conflict), id: id, accountID: accountID)
                    return try await store.draft(id: id, accountID: accountID)
                }
                try await validatePublication(
                    draft, reason: reason, expectedGeneration: expectedGeneration,
                    shouldPublish: shouldPublish)
                try await store.beginAttempt(
                    id: id, accountID: accountID, content: draft.text,
                    generation: draft.generation, remote: remote
                )
                notBefore = .now.addingTimeInterval(durationSeconds(mutationInterval))
                let result = try await client.updateGist(
                    id: gistID, files: [draft.filename: .content(draft.text)]
                )
                let acknowledged = try await client.content(gist: result, filename: draft.filename)
                guard sourceEqual(acknowledged, draft.text) else { throw DraftError.remoteDidNotAcknowledge }
                notBefore = .now.addingTimeInterval(durationSeconds(mutationInterval))
                return try await store.acknowledge(
                    id: id, accountID: accountID, gistID: gistID, content: acknowledged,
                    revision: result.revision, generation: draft.generation
                )
            } else {
                try await validatePublication(
                    draft, reason: reason, expectedGeneration: expectedGeneration,
                    shouldPublish: shouldPublish)
                try await store.beginAttempt(
                    id: id, accountID: accountID, content: draft.text,
                    generation: draft.generation, remote: nil
                )
                notBefore = .now.addingTimeInterval(durationSeconds(mutationInterval))
                let result = try await client.createGist(
                    description: draft.description, filename: draft.filename,
                    content: GistConventions.encodeContent(draft.text)
                )
                let acknowledged = try await client.content(gist: result, filename: draft.filename)
                guard sourceEqual(acknowledged, draft.text) else { throw DraftError.remoteDidNotAcknowledge }
                notBefore = .now.addingTimeInterval(durationSeconds(mutationInterval))
                return try await store.acknowledge(
                    id: id, accountID: accountID, gistID: result.id, content: acknowledged,
                    revision: result.revision, generation: draft.generation
                )
            }

        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let latest = try await store.draft(id: id, accountID: accountID)
            let state: SaveState
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
            } else if let error = error as? URLError,
                      [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                       .cannotConnectToHost, .cannotFindHost, .dataNotAllowed].contains(error.code) {
                state = .offline
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
        guard !draft.autosavePaused,
              expectedGeneration == nil || draft.generation == expectedGeneration,
              await shouldPublish() else { throw CancellationError() }
        let latest = try await store.draft(id: draft.id, accountID: draft.accountID)
        guard latest.generation == draft.generation, !latest.autosavePaused,
              latest.attemptedGeneration == nil else { throw CancellationError() }
        if case .conflict = latest.state { throw CancellationError() }
    }

    public func reconcileCreation(
        id: UUID, accountID: UUID, createdGistID: String
    ) async throws -> DraftSnapshot {
        try await attachCreation(id: id, accountID: accountID, createdGistID: createdGistID, requiringAttempt: true)
    }

    func adoptDailyCreation(id: UUID, accountID: UUID, createdGistID: String) async throws -> DraftSnapshot {
        try await attachCreation(id: id, accountID: accountID, createdGistID: createdGistID, requiringAttempt: false)
    }

    private func attachCreation(
        id: UUID, accountID: UUID, createdGistID: String, requiringAttempt: Bool
    ) async throws -> DraftSnapshot {
        await acquire()
        defer { release() }
        let draft = try await store.draft(id: id, accountID: accountID)
        if draft.gistID == createdGistID { return draft }
        guard draft.gistID == nil, !requiringAttempt || draft.attemptedGeneration != nil else {
            throw DraftError.ambiguousCreation
        }
        let attempted = draft.attemptedContent ?? draft.text
        let generation = draft.attemptedGeneration ?? draft.generation
        let gist = try await client.gist(id: createdGistID)
        guard gist.owner?.id == draft.githubUserID else { throw DraftError.readOnly }
        guard gist.truncated != true else { throw GitHubClientError.incompleteGist }
        let content = try await client.content(gist: gist, filename: draft.filename)
        guard sourceEqual(content, attempted) else { throw DraftError.remoteDidNotAcknowledge }
        return try await store.acknowledge(
            id: id, accountID: accountID, gistID: gist.id,
            content: content, revision: gist.revision, generation: generation
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

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
