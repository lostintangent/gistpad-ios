import Foundation
import Testing
@testable import GistPadSync

@Suite struct RemoteInspectionTests {
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
