import Foundation

public enum PublishReason: Equatable, Sendable {
    case manual
    case autosave
    case background
}

public actor DraftPublisher {
    private let client: GitHubClient
    private let store: DraftStore

    public init(client: GitHubClient, store: DraftStore) {
        self.client = client
        self.store = store
    }

    /// Publishes the draft: if GitHub has its base, its sent text or already its text, your text is
    /// sent, and anything else on GitHub is a conflict. Autosave and lifecycle publishes are checked
    /// once before reaching GitHub, and typing during the publish hands over to the publish that
    /// typing schedules. Callers run one publish at a time, through the library's queue for GitHub
    /// writes.
    @discardableResult
    public func publish(
        id: UUID, accountID: UUID, reason: PublishReason = .manual, expectedGeneration: UInt64? = nil,
        shouldPublish: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> Draft {
        try Task.checkCancellation()
        var draft = try await store.draft(id: id, accountID: accountID)
        if draft.isPublished { return draft }
        if case .conflict = draft.state { return draft }
        if reason != .manual {
            guard expectedGeneration == nil || draft.generation == expectedGeneration,
                  await shouldPublish() else { throw CancellationError() }
        }
        do {
            if draft.gistID == nil, let sent = draft.sent {
                draft = try await findCreatedGist(sent, for: draft)
                if draft.isPublished { return draft }
            }
            if draft.gistID == nil, draft.description == DailyNote.gistDescription {
                draft = try await joinDailyGist(draft)
            }
            if let gistID = draft.gistID {
                draft = try await compareWithGitHub(draft, gistID: gistID)
                // Newer text from the web reaches a published note when it's opened, not by publishing.
                if draft.isPublished { return draft }
                if case .conflict = draft.state { return draft }
            }
            return try await send(draft)
        } catch {
            // Sent text stays on the draft, so the next publish checks GitHub for it first.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            try await store.setState(Self.state(after: error), id: id, accountID: accountID)
            throw error
        }
    }

    /// sent ← your text, then GitHub ← sent. When GitHub confirms, base ← sent.
    private func send(_ draft: Draft) async throws -> Draft {
        try await store.recordSent(
            id: draft.id, accountID: draft.accountID, content: draft.text, generation: draft.generation)
        let gist: Gist
        if let gistID = draft.gistID {
            gist = try await client.updateGist(id: gistID, files: [draft.filename: .content(draft.text)])
        } else {
            gist = try await client.createGist(
                description: draft.description, filename: draft.filename,
                content: GistFile.encodeContent(draft.text))
        }
        let confirmed = try await client.content(gist: gist, filename: draft.filename)
        guard sourceEqual(confirmed, draft.text) else { throw DraftError.notConfirmed }
        return try await store.confirm(
            id: draft.id, accountID: draft.accountID, gistID: draft.gistID ?? gist.id, content: confirmed,
            revision: gist.revision, publishedGist: gist)
    }

    /// Reads GitHub's copy of the file. Sent text GitHub doesn't have is forgotten, and the store
    /// confirms the sent text or your text if GitHub has either, or raises a conflict unless GitHub
    /// still has the base.
    private func compareWithGitHub(_ draft: Draft, gistID: String) async throws -> Draft {
        let github = try await client.remoteFile(
            gistID: gistID, ownerID: draft.githubUserID, filename: draft.filename)
        var draft = draft
        if let sent = draft.sent, !sourceEqual(github.content, sent) {
            draft = try await store.forgetSent(id: draft.id, accountID: draft.accountID)
        }
        return try await store.compareWithGitHub(
            id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation,
            remote: github.content, revision: github.gist.revision, gist: github.gist)
    }

    /// A create that was cut off may have made the gist already. It's found by its description and
    /// a same-named file with the sent bytes, so a gist is never created twice, and sent is
    /// confirmed. Otherwise sent is forgotten.
    private func findCreatedGist(_ sent: String, for draft: Draft) async throws -> Draft {
        let size = GistFile.encodeContent(sent).utf8.count
        for gist in try await client.listGists()
        where (gist.description ?? "") == draft.description && gist.files[draft.filename]?.size == size {
            let github = try await client.remoteFile(
                gistID: gist.id, ownerID: draft.githubUserID, filename: draft.filename)
            if sourceEqual(github.content, sent) {
                return try await store.confirm(
                    id: draft.id, accountID: draft.accountID, gistID: github.gist.id, content: sent,
                    revision: github.gist.revision, publishedGist: github.gist)
            }
        }
        return try await store.forgetSent(id: draft.id, accountID: draft.accountID)
    }

    /// A new day joins the Daily notes gist GitHub has, which the web may have started since this
    /// iPhone last saw the list, and creates one only when there's none.
    private func joinDailyGist(_ draft: Draft) async throws -> Draft {
        guard let daily = try await client.listGists().first(where: \.isDailyNote) else { return draft }
        return try await store.join(gistID: daily.id, id: draft.id, accountID: draft.accountID)
    }

    /// What you see after a publish fails.
    private static func state(after error: Error) -> PublishState {
        switch error {
        case GitHubClientError.http(status: 401), is AccountError: .reconnect
        case GitHubClientError.http(let status): .failed(.http(status: status))
        case GitHubClientError.incompleteGist, GitHubClientError.fileTooLarge: .failed(.incompleteRemote)
        case DraftError.readOnly: .failed(.readOnly)
        default: .failed(.network)
        }
    }
}
