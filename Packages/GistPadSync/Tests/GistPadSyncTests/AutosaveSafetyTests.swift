import Foundation
import Synchronization
import Testing
@testable import GistPadSync

@Suite struct AutosaveSafetyTests {
    @Test(arguments: [false, true])
    func cancellationAfterAnAttemptPreservesExplicitUncertainty(isNew: Bool) async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft: DraftSnapshot
        if isNew {
            draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "base")
        } else {
            draft = try await store.openDraft(
                accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
                description: "Note", content: "base", revision: "one")
        }
        _ = try await store.persist(id: draft.id, accountID: account, text: "local", generation: 1)
        let tokens = Mutex(0)
        let methods = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(content: "base"))
        }) {
            let count = tokens.withLock { $0 += 1; return $0 }
            if count == (isNew ? 1 : 2) { throw CancellationError() }
            return "fake"
        }
        let coordinator = SyncCoordinator(client: client, store: store, mutationInterval: .zero)
        await #expect(throws: CancellationError.self) {
            try await coordinator.publish(id: draft.id, accountID: account)
        }
        let retained = try await store.draft(id: draft.id, accountID: account)
        #expect(retained.state == .failed(isNew ? .creationUncertain : .publicationUncertain))
        #expect(retained.attemptedGeneration == 1)
        #expect(retained.text == "local")
        #expect(methods.withLock { $0 } == (isNew ? [] : ["GET"]))
    }

    @Test func resolvedReviewStaysPausedAcrossRelaunchAndTyping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let store = try DraftStore.open(url: url)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        try await store.setState(.conflict(DraftConflict(
            generation: 0, base: "base", local: "base", remote: "remote",
            remoteRevision: "two", suggestedMerge: nil)), id: draft.id, accountID: account)
        let resolved = try await store.resolveConflict(
            id: draft.id, accountID: account, expectedGeneration: 0, text: "base", generation: 0)
        #expect(resolved.autosavePaused)
        let reopened = try DraftStore.open(url: url)
        #expect(try await reopened.draft(id: draft.id, accountID: account).autosavePaused)
        let typed = try await reopened.persist(
            id: draft.id, accountID: account, text: "later typing", generation: 1)
        #expect(typed.autosavePaused)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            Issue.record("Paused autosave must not make a network request.")
            return FakeResponse(status: 500)
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: reopened)
        await #expect(throws: CancellationError.self) {
            try await coordinator.publish(id: draft.id, accountID: account, reason: .autosave)
        }
        #expect(try await reopened.draft(id: draft.id, accountID: account).state == .savedLocally)
    }

    @Test func explicitPublicationResumesAutosaveAfterReview() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        try await store.setState(.conflict(DraftConflict(
            generation: 0, base: "base", local: "base", remote: "remote",
            remoteRevision: "two", suggestedMerge: nil)), id: draft.id, accountID: account)
        _ = try await store.resolveConflict(
            id: draft.id, accountID: account, expectedGeneration: 0, text: "local", generation: 1)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            FakeResponse(data: try gistData(
                content: request.httpMethod == "PATCH" ? "local" : "remote", revision: "two"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store, mutationInterval: .zero)
        let saved = try await coordinator.publish(id: draft.id, accountID: account, reason: .manual)
        #expect(saved.state == .savedToGitHub)
        #expect(!saved.autosavePaused)
    }

    @Test func compositionOrLifecycleChangeDuringFreshReadBlocksThePatch() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        _ = try await store.persist(id: draft.id, accountID: account, text: "local", generation: 1)
        let allowed = Mutex(true)
        let methods = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            allowed.withLock { $0 = false }
            return FakeResponse(data: try gistData(content: "base"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        await #expect(throws: CancellationError.self) {
            try await coordinator.publish(
                id: draft.id, accountID: account, reason: .autosave, expectedGeneration: 1,
                shouldPublish: { allowed.withLock { $0 } })
        }
        #expect(methods.withLock { $0 } == ["GET"])
        let kept = try await store.draft(id: draft.id, accountID: account)
        #expect(kept.state == .savedLocally)
        #expect(kept.attemptedGeneration == nil)
        #expect(kept.text == "local")
    }

    @Test func newerGenerationDuringFreshReadIsNotPublishedByAnOlderTimer() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        _ = try await store.persist(id: draft.id, accountID: account, text: "local", generation: 1)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            _ = try await store.persist(id: draft.id, accountID: account, text: "newer", generation: 2)
            return FakeResponse(data: try gistData(content: "base"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        await #expect(throws: CancellationError.self) {
            try await coordinator.publish(
                id: draft.id, accountID: account, reason: .autosave, expectedGeneration: 1)
        }
        #expect(try await store.draft(id: draft.id, accountID: account).text == "newer")
    }
}
