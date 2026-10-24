import Foundation
import Testing
@testable import GistPadSync

@Suite struct ConflictRefreshTests {
    @Test func typingAndUndoPreserveTheInspectedConflictUntilExplicitResolution() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "a\nb\nc", revision: "one"
        )
        let inspected = DraftConflict(
            generation: 0, base: draft.text, local: draft.text, remote: "a\nb\nC",
            remoteRevision: "two", suggestedMerge: "a\nb\nC"
        )
        try await store.setState(.conflict(inspected), id: draft.id, accountID: account)
        let typed = try await store.persist(
            id: draft.id, accountID: account, text: "A\nb\nc", generation: 1
        )
        guard case .conflict(let updated) = typed.state else {
            Issue.record("Typing cannot silently resolve a conflict")
            return
        }
        #expect(updated.generation == 1)
        #expect(updated.local == typed.text)
        #expect(updated.remote == inspected.remote)
        #expect(updated.remoteRevision == "two")
        #expect(updated.suggestedMerge == "A\nb\nC")
        let undone = try await store.persist(
            id: draft.id, accountID: account, text: draft.text, generation: 2
        )
        guard case .conflict(let reverted) = undone.state else {
            Issue.record("Undo back to the old base cannot acknowledge the newer remote")
            return
        }
        #expect(reverted.generation == 2)
        #expect(reverted.local == draft.text)
        #expect(reverted.remote == inspected.remote)
        #expect(reverted.suggestedMerge == inspected.remote)
        #expect(undone.baseRevision == "one")
    }

    @Test func refreshReplacesOnlyInspectedRemoteAndRecomputesUnresolvedMerge() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "a\nb\nc", revision: "one"
        )
        _ = try await store.persist(id: draft.id, accountID: account, text: "A\nb\nc", generation: 1)
        let inspected = DraftConflict(
            generation: 1, base: draft.text, local: "A\nb\nc", remote: "other",
            remoteRevision: "two", suggestedMerge: nil
        )
        try await store.setState(.conflict(inspected), id: draft.id, accountID: account)
        let refreshed = try await store.refreshConflict(
            id: draft.id, accountID: account, expectedGeneration: 1,
            expectedConflict: inspected, remote: "a\nb\nC", revision: "three"
        )
        #expect(refreshed.text == "A\nb\nc")
        #expect(refreshed.generation == 1)
        #expect(refreshed.baseContent == draft.baseContent)
        #expect(refreshed.baseRevision == "one")
        guard case .conflict(let conflict) = refreshed.state else {
            Issue.record("Refreshing review must not resolve or publish the conflict")
            return
        }
        #expect(conflict.remote == "a\nb\nC")
        #expect(conflict.remoteRevision == "three")
        #expect(conflict.suggestedMerge == "A\nb\nC")
        await #expect(throws: DraftError.unresolvedConflict) {
            try await store.refreshConflict(
                id: draft.id, accountID: account, expectedGeneration: 1,
                expectedConflict: inspected, remote: "stale response", revision: "four"
            )
        }
        let missing = try await store.refreshConflict(
            id: draft.id, accountID: account, expectedGeneration: 1,
            expectedConflict: conflict, remote: nil, revision: "four"
        )
        guard case .conflict(let deleted) = missing.state else {
            Issue.record("A verified missing file remains a conflict")
            return
        }
        #expect(deleted.remote == nil)
        #expect(deleted.suggestedMerge == nil)
        #expect(missing.text == refreshed.text)
    }

    @Test func staleGenerationWrongAccountAndNonConflictCannotBeRefreshed() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "local")
        let inspected = DraftConflict(
            generation: 0, base: nil, local: "local", remote: "remote",
            remoteRevision: "one", suggestedMerge: nil
        )
        await #expect(throws: DraftError.unresolvedConflict) {
            try await store.refreshConflict(
                id: draft.id, accountID: account, expectedGeneration: 0,
                expectedConflict: inspected, remote: "next", revision: "two"
            )
        }
        try await store.setState(.conflict(inspected), id: draft.id, accountID: account)
        await #expect(throws: DraftError.accountMismatch) {
            try await store.refreshConflict(
                id: draft.id, accountID: UUID(), expectedGeneration: 0,
                expectedConflict: inspected, remote: "next", revision: "two"
            )
        }
        _ = try await store.persist(id: draft.id, accountID: account, text: "new local", generation: 1)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.refreshConflict(
                id: draft.id, accountID: account, expectedGeneration: 0,
                expectedConflict: inspected, remote: "next", revision: "two"
            )
        }
        #expect(try await store.draft(id: draft.id, accountID: account).text == "new local")
    }

    @Test func inspectedSnapshotComparisonUsesSourceBytes() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "local")
        let current = DraftConflict(
            generation: 0, base: nil, local: "local", remote: "\u{e9}",
            remoteRevision: "one", suggestedMerge: nil
        )
        let equivalent = DraftConflict(
            generation: 0, base: nil, local: "local", remote: "e\u{301}",
            remoteRevision: "one", suggestedMerge: nil
        )
        #expect(current == equivalent)
        try await store.setState(.conflict(current), id: draft.id, accountID: account)
        await #expect(throws: DraftError.unresolvedConflict) {
            try await store.refreshConflict(
                id: draft.id, accountID: account, expectedGeneration: 0,
                expectedConflict: equivalent, remote: "next", revision: "two"
            )
        }
    }
}
