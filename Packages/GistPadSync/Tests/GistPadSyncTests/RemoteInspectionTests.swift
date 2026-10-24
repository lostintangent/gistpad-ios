import Foundation
import Synchronization
import Testing
@testable import GistPadSync

@Suite struct RemoteInspectionTests {
    @Test func aLandedPatchWithoutLocalAcknowledgementIsQuietlyAdoptedAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let first = try DraftStore.open(url: url)
        let draft = try await first.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        let text = "# Saved\r\n\r\n日本語 👩🏽‍💻 e\u{301}\r\n"
        _ = try await first.persist(id: draft.id, accountID: account, text: text, generation: 1)
        try await first.beginAttempt(
            id: draft.id, accountID: account, content: text, generation: 1, remote: "base")
        let methods = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            return FakeResponse(data: try gistData(content: text, revision: "two"))
        }) { "fake" }
        _ = try await client.updateGist(id: "abc123", files: ["README.md": .content(text)])
        // The durable attempt survives when the post-PATCH acknowledgement cannot commit.
        let reopened = try DraftStore.open(url: url)
        let uncertain = try await reopened.draft(id: draft.id, accountID: account)
        #expect(uncertain.state == .failed(.publicationUncertain))
        #expect(uncertain.attemptedGeneration == 1)
        let remote = try await client.gist(id: "abc123")
        let content = try await client.content(gist: remote, filename: "README.md")
        let adopted = try await reopened.inspectRemoteChange(
            id: draft.id, accountID: account, expectedGeneration: 1,
            remote: content, revision: remote.revision)
        #expect(adopted.id == draft.id)
        #expect(adopted.text.utf8.elementsEqual(text.utf8))
        #expect(adopted.baseContent?.utf8.elementsEqual(text.utf8) == true)
        #expect(adopted.baseRevision == "two")
        #expect(adopted.generation == 1)
        #expect(adopted.state == .savedToGitHub)
        #expect(adopted.attemptedGeneration == nil)
        #expect(adopted.attemptedContent == nil)
        #expect(methods.withLock { $0 } == ["PATCH", "GET"])
        let again = try DraftStore.open(url: url)
        #expect(try await again.draft(id: draft.id, accountID: account).state == .savedToGitHub)
        let coordinator = SyncCoordinator(client: client, store: again, mutationInterval: .zero)
        #expect(try await coordinator.publish(id: draft.id, accountID: account).state == .savedToGitHub)
        #expect(methods.withLock { $0 } == ["PATCH", "GET", "GET"])
    }

    @Test func recoveringAnOlderAcknowledgementPreservesNewerUnpublishedTyping() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        _ = try await store.persist(id: draft.id, accountID: account, text: "sent", generation: 1)
        try await store.beginAttempt(
            id: draft.id, accountID: account, content: "sent", generation: 1, remote: "base")
        _ = try await store.persist(id: draft.id, accountID: account, text: "newer", generation: 2)
        try await store.setState(.failed(.publicationUncertain), id: draft.id, accountID: account)
        let adopted = try await store.inspectRemoteChange(
            id: draft.id, accountID: account, expectedGeneration: 2, remote: "sent", revision: "two")
        #expect(adopted.text == "newer")
        #expect(adopted.generation == 2)
        #expect(adopted.baseContent == "sent")
        #expect(adopted.baseRevision == "two")
        #expect(adopted.state == .savedLocally)
        #expect(adopted.attemptedGeneration == nil)
    }

    @Test(arguments: [String?.none, "different", "e\u{301}"])
    func uncertainInspectionRequiresExactRemoteBytes(remote: String?) async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        _ = try await store.persist(id: draft.id, accountID: account, text: "\u{e9}", generation: 1)
        try await store.beginAttempt(
            id: draft.id, accountID: account, content: "\u{e9}", generation: 1, remote: "base")
        await #expect(throws: DraftError.publishInProgress) {
            try await store.inspectRemoteChange(
                id: draft.id, accountID: account, expectedGeneration: 1,
                remote: "\u{e9}", revision: "two")
        }
        try await store.setState(.failed(.publicationUncertain), id: draft.id, accountID: account)
        let uncertain = try await store.inspectRemoteChange(
            id: draft.id, accountID: account, expectedGeneration: 1, remote: remote, revision: "two")
        #expect(uncertain.state == .failed(.publicationUncertain))
        #expect(uncertain.attemptedGeneration == 1)
        #expect(uncertain.attemptedContent?.utf8.elementsEqual("\u{e9}".utf8) == true)
        #expect(uncertain.baseContent == "base")
        #expect(uncertain.baseRevision == "one")
    }

    @Test func inspectionKeepsSourceAndGenerationAndFreezesTheReviewedRemote() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        let inspected = try await store.inspectRemoteChange(
            id: draft.id, accountID: account, expectedGeneration: 0,
            remote: "changed remotely", revision: "two")
        #expect(inspected.text == "base")
        #expect(inspected.generation == 0)
        guard case .conflict(let conflict) = inspected.state else {
            Issue.record("A retained clean source must disclose a remote change.")
            return
        }
        #expect(conflict.remote == "changed remotely")
        let again = try await store.inspectRemoteChange(
            id: draft.id, accountID: account, expectedGeneration: 0,
            remote: "changed a second time", revision: "three")
        #expect(again.state == inspected.state)
        #expect(try await store.recoveries(id: draft.id, accountID: account).isEmpty)
    }

    @Test func missingFileAndStaleGenerationCannotBecomeAnEmptyBaseline() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        _ = try await store.persist(id: draft.id, accountID: account, text: "local", generation: 1)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.inspectRemoteChange(
                id: draft.id, accountID: account, expectedGeneration: 0,
                remote: nil, revision: "two")
        }
        let inspected = try await store.inspectRemoteChange(
            id: draft.id, accountID: account, expectedGeneration: 1,
            remote: nil, revision: "two")
        guard case .conflict(let conflict) = inspected.state else {
            Issue.record("A missing file must remain an explicit unresolved conflict.")
            return
        }
        #expect(conflict.remote == nil)
        #expect(inspected.baseContent == "base")
        #expect(inspected.text == "local")
    }
}
