import Foundation
import Synchronization
import Testing
@testable import GistPadSync

private actor Signal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private func editedDraft(
    store: DraftStore, account: UUID, base: String = "base", text: String = "local"
) async throws -> DraftSnapshot {
    let draft = try await store.openDraft(
        accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
        description: "Note", content: base, revision: "revision1"
    )
    return try await store.persist(id: draft.id, accountID: account, text: text, generation: 1)
}

@Suite struct SyncTests {
    @Test func creationAcknowledgementImmediatelyPromotesItsCachedLibraryRowWithoutAnotherGet() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        try await store.cacheLibrary(owned: [], starred: [], preferences: .init(metadata: [:]), accountID: account)
        let draft = try await store.newDraft(
            accountID: account, githubUserID: 42, description: "New note", text: "published")
        let methods = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            #expect(request.httpMethod == "POST")
            return FakeResponse(data: try gistData(content: "published", description: "New note"))
        }) { "fake" }
        let saved = try await SyncCoordinator(client: client, store: store, mutationInterval: .zero)
            .publish(id: draft.id, accountID: account)
        let cached = try #require(await store.cachedLibrary(accountID: account))
        #expect(saved.gistID == "abc123")
        #expect(cached.owned.map(\.id) == ["abc123"])
        #expect(cached.details["abc123"]?.owner?.id == 42)
        #expect(cached.fileContent["abc123/README.md"]?.text == "published")
        #expect(methods.withLock { $0 } == ["POST"])
    }

    @Test func durableDraftSurvivesContainerReopenAndIsAccountIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let store = try DraftStore.open(url: url)
        let draft = try await editedDraft(store: store, account: account, text: "Emoji \u{1F9D1}\u{200D}\u{1F4BB}\n日本語\nمرحبا")
        let reopened = try DraftStore.open(url: url)
        let restored = try await reopened.draft(id: draft.id, accountID: account)
        #expect(restored.text == draft.text)
        #expect(restored.generation == 1)
        #expect(restored.state == .savedLocally)
        #expect(try await reopened.drafts(accountID: UUID()).isEmpty)
        await #expect(throws: DraftError.accountMismatch) {
            try await reopened.draft(id: draft.id, accountID: UUID())
        }
    }

    @Test func freshReadUpdatesOnlyAnUnchangedCleanDraft() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "revision1"
        )
        let refreshed = try await store.refreshCleanDraft(
            id: draft.id, accountID: account, expectedGeneration: 0,
            content: "web change", revision: "revision2"
        )
        guard case .refreshed(let clean) = refreshed else {
            Issue.record("Expected a clean baseline refresh")
            return
        }
        #expect(clean.text == "web change")
        #expect(clean.baseContent == "web change")
        #expect(clean.generation == 1)
        #expect(clean.state == .savedToGitHub)
        _ = try await store.persist(id: draft.id, accountID: account, text: "local change", generation: 2)
        let preserved = try await store.refreshCleanDraft(
            id: draft.id, accountID: account, expectedGeneration: 2,
            content: "another web change", revision: "revision3"
        )
        guard case .preservedLocalChanges(let dirty) = preserved else {
            Issue.record("Expected the dirty draft to win locally")
            return
        }
        #expect(dirty.text == "local change")
        #expect(dirty.baseContent == "web change")
        await #expect(throws: DraftError.staleGeneration) {
            try await store.refreshCleanDraft(
                id: draft.id, accountID: account, expectedGeneration: 1,
                content: "stale response", revision: "revision2"
            )
        }
    }

    @Test func overlappingRemoteChangesNeverIssuePatch() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account)
        let calls = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            calls.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(content: "remote", revision: "revision2"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        let result = try await coordinator.publish(id: draft.id, accountID: account)
        guard case .conflict(let conflict) = result.state else {
            Issue.record("Expected an explicit conflict")
            return
        }
        #expect(conflict.base == "base")
        #expect(conflict.local == "local")
        #expect(conflict.remote == "remote")
        #expect(conflict.suggestedMerge == nil)
        #expect(result.text == "local")
        #expect(calls.withLock { $0 } == ["GET"])
    }

    @Test func cleanDraftAdoptsAChangedRemoteWithoutAConflictOrWrite() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "revision1"
        )
        let calls = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            calls.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(content: "remote", revision: "revision2"))
        }) { "fake" }
        let adopted = try await SyncCoordinator(client: client, store: store)
            .publish(id: draft.id, accountID: account, reason: .leaving)
        #expect(adopted.state == .savedToGitHub)
        #expect(adopted.text == "remote")
        #expect(adopted.baseContent == "remote")
        #expect(adopted.generation == 1)
        #expect(calls.withLock { $0 } == ["GET"])
    }

    @Test func aStuckCleanConflictClearsOnTheNextPublish() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "revision1"
        )
        try await store.setState(.conflict(DraftConflict(
            generation: draft.generation, base: "base", local: "base",
            remote: "remote", remoteRevision: "revision2"
        )), id: draft.id, accountID: account)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            FakeResponse(data: try gistData(content: "remote", revision: "revision2"))
        }) { "fake" }
        let adopted = try await SyncCoordinator(client: client, store: store)
            .publish(id: draft.id, accountID: account, reason: .background)
        #expect(adopted.state == .savedToGitHub)
        #expect(adopted.text == "remote")
        #expect(adopted.baseContent == "remote")
    }

    @Test func openAdoptsAChangedRemoteForACleanNote() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "revision1"
        )
        let calls = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            calls.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(content: "remote", revision: "revision2"))
        }) { "fake" }
        let opened = try await SyncCoordinator(client: client, store: store)
            .adoptRemoteIfClean(id: draft.id, accountID: account)
        #expect(opened.state == .savedToGitHub)
        #expect(opened.text == "remote")
        #expect(opened.baseContent == "remote")
        #expect(calls.withLock { $0 } == ["GET"])
    }

    @Test func openLeavesAnEditedNoteAloneWithoutFetching() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let edited = try await editedDraft(store: store, account: account)
        let calls = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            calls.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(content: "remote", revision: "revision2"))
        }) { "fake" }
        let opened = try await SyncCoordinator(client: client, store: store)
            .adoptRemoteIfClean(id: edited.id, accountID: account)
        #expect(opened.text == "local")
        #expect(opened.baseContent == "base")
        #expect(calls.withLock { $0 }.isEmpty)
    }

    @Test func disjointMergeIsAProposalUntilAppliedAsANewGeneration() async throws {
        let base = "one\ntwo\nthree\n"
        let local = "ONE\ntwo\nthree\n"
        let remote = "one\ntwo\nTHREE\n"
        let merged = "ONE\ntwo\nTHREE\n"
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account, base: base, text: local)
        let patches = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            if request.httpMethod == "PATCH" {
                patches.withLock { $0 += 1 }
                let body = try requestBody(request)
                let files = try #require(body["files"] as? [String: [String: String]])
                #expect(files["README.md"]?["content"] == merged)
                return FakeResponse(data: try gistData(content: merged, revision: "revision3"))
            }
            return FakeResponse(data: try gistData(content: remote, revision: "revision2"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store, mutationInterval: .zero)
        let proposal = try await coordinator.publish(id: draft.id, accountID: account)
        guard case .conflict(let conflict) = proposal.state else {
            Issue.record("Expected a merge proposal")
            return
        }
        #expect(conflict.suggestedMerge == merged)
        #expect(proposal.text == local)
        #expect(patches.withLock { $0 } == 0)
        _ = try await store.resolveConflict(
            id: draft.id, accountID: account, expectedGeneration: 1, text: merged, generation: 2
        )
        let result = try await coordinator.publish(id: draft.id, accountID: account)
        #expect(result.state == .savedToGitHub)
        #expect(patches.withLock { $0 } == 1)
    }

    @Test func newerTypingIsNeverClearedByAnOlderAcknowledgement() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account)
        let patchStarted = Signal()
        let allowResponse = Signal()
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            if request.httpMethod == "PATCH" {
                await patchStarted.signal()
                await allowResponse.wait()
                return FakeResponse(data: try gistData(content: "local", revision: "revision2"))
            }
            return FakeResponse(data: try gistData())
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        let publishing = Task { try await coordinator.publish(id: draft.id, accountID: account) }
        await patchStarted.wait()
        _ = try await store.persist(id: draft.id, accountID: account, text: "newer typing", generation: 2)
        await allowResponse.signal()
        let result = try await publishing.value
        #expect(result.text == "newer typing")
        #expect(result.generation == 2)
        #expect(result.baseContent == "local")
        #expect(result.state == .savedLocally)
    }

    @Test func keepingIdenticalDraftResolvesOnlyTheBaselineWithoutInventingAnEdit() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            return FakeResponse(data: try gistData(content: "web version", revision: "revision2"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        _ = try await coordinator.publish(id: draft.id, accountID: account)
        let result = try await store.resolveConflict(
            id: draft.id, accountID: account, expectedGeneration: 1, text: "local", generation: 1
        )
        #expect(result.text == "local")
        #expect(result.generation == 1)
        #expect(result.baseContent == "web version")
        #expect(result.baseRevision == "revision2")
        #expect(result.state == .savedLocally)
        let recovery = try #require(try await store.recoveries(id: draft.id, accountID: account).last)
        #expect(recovery.local == "local")
        #expect(recovery.base == "base")
        #expect(recovery.remote == "web version")
        #expect(recovery.generation == 1)
        await #expect(throws: DraftError.unresolvedConflict) {
            try await store.resolveConflict(
                id: draft.id, accountID: account, expectedGeneration: 1, text: "local", generation: 1
            )
        }
    }

    @Test func equalConflictGenerationRequiresExactBytesNotCanonicalUnicodeEquality() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        #expect(composed == decomposed)
        let draft = try await editedDraft(store: store, account: account, text: composed)
        try await store.setState(.conflict(DraftConflict(
            generation: 1, base: "base", local: composed, remote: "remote",
            remoteRevision: "two", suggestedMerge: nil
        )), id: draft.id, accountID: account)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.resolveConflict(
                id: draft.id, accountID: account, expectedGeneration: 1, text: decomposed, generation: 1
            )
        }
        #expect(try await store.draft(id: draft.id, accountID: account).text.utf8.elementsEqual(composed.utf8))
        #expect(try await store.recoveries(id: draft.id, accountID: account).isEmpty)
        let accepted = try await store.resolveConflict(
            id: draft.id, accountID: account, expectedGeneration: 1, text: decomposed, generation: 2
        )
        #expect(accepted.text.utf8.elementsEqual(decomposed.utf8))
        #expect(accepted.generation == 2)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.resolveConflict(
                id: draft.id, accountID: account, expectedGeneration: 1, text: decomposed, generation: 1
            )
        }
    }

    @Test func ambiguousPatchReconcilesWithoutRepeatingTheWrite() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account)
        let remote = Mutex("base")
        let patches = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            if request.httpMethod == "PATCH" {
                patches.withLock { $0 += 1 }
                remote.withLock { $0 = "local" }
                throw URLError(.timedOut)
            }
            return FakeResponse(data: try gistData(content: remote.withLock { $0 }))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store, mutationInterval: .zero)
        await #expect(throws: (any Error).self) {
            try await coordinator.publish(id: draft.id, accountID: account)
        }
        let offline = try await store.draft(id: draft.id, accountID: account)
        #expect(offline.state == .offline)
        #expect(offline.text == "local")
        #expect(offline.attemptedContent == "local")
        let result = try await coordinator.publish(id: draft.id, accountID: account)
        #expect(result.state == .savedToGitHub)
        #expect(result.attemptedGeneration == nil)
        #expect(patches.withLock { $0 } == 1)
    }

    @Test func ambiguousCreateCannotBeBlindlyRetriedEvenWithANewCoordinator() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "new note")
        let creates = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            creates.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }) { "fake" }
        let first = SyncCoordinator(client: client, store: store)
        await #expect(throws: (any Error).self) {
            try await first.publish(id: draft.id, accountID: account)
        }
        let restored = try await store.draft(id: draft.id, accountID: account)
        #expect(restored.state == .failed(.creationUncertain))
        let next = SyncCoordinator(client: client, store: store)
        await #expect(throws: DraftError.ambiguousCreation) {
            try await next.publish(id: draft.id, accountID: account)
        }
        #expect(creates.withLock { $0 } == 1)
        #expect(restored.text == "new note")
    }

    @Test func backgroundSavePublishesEvenWithAutosaveDisabled() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account)
        let calls = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            calls.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(
                content: request.httpMethod == "PATCH" ? "local" : "base"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store, mutationInterval: .zero)
        let result = try await coordinator.publish(
            id: draft.id, accountID: account, reason: .background, autosaveEnabled: false
        )
        #expect(result.state == .savedToGitHub)
        #expect(result.text == "local")
        #expect(result.baseContent == "local")
        #expect(calls.withLock { $0 } == ["GET", "PATCH"])
    }

    @Test func disabledAutosaveStillSkipsTimedPublication() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await editedDraft(store: store, account: account)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            Issue.record("Disabled timed autosave must not make a network request.")
            return FakeResponse(status: 500)
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        let result = try await coordinator.publish(
            id: draft.id, accountID: account, reason: .autosave, autosaveEnabled: false)
        #expect(result.state == .savedLocally)
        #expect(result.text == "local")
    }

    @Test func inaccessibleAndForeignGistsRetainTheDraft() async throws {
        for status in [404, 200] {
            let account = UUID()
            let store = try DraftStore.open(inMemory: true)
            let draft = try await editedDraft(store: store, account: account)
            let client = GitHubClient(session: FakeURLProtocol.session { request in
                #expect(request.httpMethod == "GET")
                return FakeResponse(status: status, data: try gistData(owner: 99))
            }) { "fake" }
            let coordinator = SyncCoordinator(client: client, store: store)
            await #expect(throws: (any Error).self) {
                try await coordinator.publish(id: draft.id, accountID: account)
            }
            let retained = try await store.draft(id: draft.id, accountID: account)
            #expect(retained.text == "local")
            #expect(retained.state == (status == 404
                ? .failed(.http(status: 404, retryAfter: nil)) : .failed(.readOnly)))
        }
    }

    @Test func byteExactMergePreservesCombiningCharactersAndLineEndings() {
        #expect(ThreeWayMerge.merge(base: "a\r\nb\r\n", local: "A\r\nb\r\n", remote: "a\r\nB\r\n")
            == "A\r\nB\r\n")
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        let merged = ThreeWayMerge.merge(base: composed, local: decomposed, remote: composed)
        #expect(merged?.utf8.elementsEqual(decomposed.utf8) == true)
        #expect(ThreeWayMerge.merge(base: "a\n", local: "a\nleft\n", remote: "a\nright\n") == nil)
    }

    @Test func interruptedPublishingRecoversAsUncertainNotStillSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let first = try DraftStore.open(url: url)
        let draft = try await editedDraft(store: first, account: account)
        try await first.beginAttempt(
            id: draft.id, accountID: account, content: "local", generation: 1, remote: "base"
        )
        let reopened = try DraftStore.open(url: url)
        let recovered = try await reopened.draft(id: draft.id, accountID: account)
        #expect(recovered.state == .failed(.publicationUncertain))
        #expect(recovered.attemptedContent == "local")
        let updated = try await reopened.persist(
            id: draft.id, accountID: account, text: "later text", generation: 2
        )
        #expect(updated.state == .failed(.publicationUncertain))
        #expect(try await reopened.recoveries(id: draft.id, accountID: account).count == 1)
    }

    @Test func explicitScratchSelectionCanReconcileAnAmbiguousCreation() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "new note")
        try await store.beginAttempt(
            id: draft.id, accountID: account, content: "new note", generation: 0, remote: nil
        )
        try await store.setState(.failed(.creationUncertain), id: draft.id, accountID: account)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            return FakeResponse(data: try gistData(content: "new note"))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        let result = try await coordinator.reconcileCreation(
            id: draft.id, accountID: account, createdGistID: "abc123"
        )
        #expect(result.gistID == "abc123")
        #expect(result.state == .savedToGitHub)
    }
}
