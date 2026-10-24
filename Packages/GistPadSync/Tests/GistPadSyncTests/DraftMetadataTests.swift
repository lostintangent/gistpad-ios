import Foundation
import Testing
@testable import GistPadSync

@Suite struct DraftMetadataTests {
    @Test func metadataChangesRetainSourceGenerationAndRecoveryHistory() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Before", content: "base", revision: "one"
        )
        _ = try await store.persist(id: draft.id, accountID: account, text: "local", generation: 1)
        try await store.beginAttempt(id: draft.id, accountID: account, content: "local", generation: 1, remote: "base")
        await #expect(throws: DraftMetadataError.publicationPending) {
            try await store.updateDraftMetadata(
                id: draft.id, accountID: account, expectedFilename: "README.md", filename: "New.md", description: "After"
            )
        }
        try await store.clearAttempt(id: draft.id, accountID: account)
        let before = try await store.draft(id: draft.id, accountID: account)
        let changed = try await store.updateDraftMetadata(
            id: draft.id, accountID: account, expectedFilename: "README.md", filename: "New.md", description: "After"
        )
        #expect(changed.id == before.id)
        #expect(changed.filename == "New.md")
        #expect(changed.description == "After")
        #expect(changed.text == before.text)
        #expect(changed.generation == before.generation)
        #expect(changed.baseContent == before.baseContent)
        #expect(changed.baseRevision == before.baseRevision)
        #expect(changed.state == before.state)
        #expect(try await store.recoveries(id: draft.id, accountID: account).first?.local == "local")
        #expect(try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "New.md",
            description: "After", content: "remote", revision: "two"
        ).id == draft.id)
    }

    @Test func metadataGuardsPreventCollisionStaleResponsesAndAccountLeakage() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let one = try await store.newFileDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "One.md", description: "", text: "one"
        )
        _ = try await store.newFileDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "Two.md", description: "", text: "two"
        )
        await #expect(throws: DraftMetadataError.filenameInUse) {
            try await store.updateDraftMetadata(
                id: one.id, accountID: account, expectedFilename: "One.md", filename: "Two.md", description: ""
            )
        }
        await #expect(throws: DraftMetadataError.staleMetadata) {
            try await store.updateDraftMetadata(
                id: one.id, accountID: account, expectedFilename: "Gone.md", filename: "Three.md", description: ""
            )
        }
        await #expect(throws: DraftError.accountMismatch) {
            try await store.updateDraftMetadata(
                id: one.id, accountID: UUID(), expectedFilename: "One.md", filename: "Three.md", description: ""
            )
        }
        for filename in ["", "folder/file.md", "bad\nname.md"] {
            await #expect(throws: DraftMetadataError.invalidFilename) {
                try await store.updateDraftMetadata(
                    id: one.id, accountID: account, expectedFilename: "One.md", filename: filename, description: ""
                )
            }
        }
        #expect(try await store.draft(id: one.id, accountID: account).filename == "One.md")
    }

    @Test func confirmedDeletionRemovesOnlyCleanDraftsWithoutRecoveryCopies() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        func open(_ filename: String, accountID: UUID) async throws -> DraftSnapshot {
            try await store.openDraft(
                accountID: accountID, githubUserID: 42, gistID: "abc123", filename: filename,
                description: "", content: "base", revision: "one"
            )
        }
        let clean = try await open("Clean.md", accountID: account)
        let dirty = try await open("Dirty.md", accountID: account)
        _ = try await store.persist(id: dirty.id, accountID: account, text: "unsynced", generation: 1)
        let historical = try await open("History.md", accountID: account)
        try await store.beginAttempt(
            id: historical.id, accountID: account, content: "base", generation: 0, remote: "base"
        )
        _ = try await store.acknowledge(
            id: historical.id, accountID: account, gistID: "abc123", content: "base", revision: "two", generation: 0
        )
        let foreign = try await open("Foreign.md", accountID: UUID())
        let result = try await store.removeCleanDraftsForDeletedGist(gistID: "abc123", accountID: account)
        #expect(result.removedDraftIDs == [clean.id])
        #expect(Set(result.retainedDrafts.map(\.id)) == [dirty.id, historical.id])
        #expect(try await store.recoveries(id: historical.id, accountID: account).count == 1)
        #expect(try await store.draft(id: foreign.id, accountID: foreign.accountID).text == "base")
        await #expect(throws: DraftError.notFound) {
            try await store.draft(id: clean.id, accountID: account)
        }
    }
}
