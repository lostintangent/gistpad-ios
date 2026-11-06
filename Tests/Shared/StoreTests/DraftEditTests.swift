import Foundation
import SwiftData
import Testing
@testable import Store

@Suite struct DraftEditTests {
    @Test func aStaleAdditionNeverMutatesTheDraft() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let text = "- [ ] Task"
        let opened = Draft(accountID: account, githubUserID: 42)
        let typed = try await store.save(opened, text: text, generation: 1)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.apply(DraftEdit(draft: opened, text: "x"))
        }
        #expect(try await store.draft(id: typed.id, accountID: account)?.text == text)
    }

    /// Earlier builds also kept drafts with nothing GitHub lacks, which go when the store opens.
    @Test func schemaChangesKeepDraftsAndDropRetiredRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let id = UUID()
        do {
            let schema = Schema([
                RetiredSchema.StoredDraft.self, RetiredSchema.StoredRecovery.self,
                RetiredSchema.StoredCommandReceipt.self
            ])
            let configuration = ModelConfiguration("GistPadDrafts", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let draft = RetiredSchema.StoredDraft(
                id: id, accountID: account, githubUserID: 42, gistID: "abc123",
                filename: "README.md", description: "Note", text: "unsynced source",
                baseContent: "remote base", baseRevision: "one",
                stateData: try JSONEncoder().encode(PublishState.savedLocally)
            )
            draft.generation = 7
            draft.autosavePaused = true
            context.insert(draft)
            context.insert(RetiredSchema.StoredDraft(
                id: UUID(), accountID: account, githubUserID: 42, gistID: "abc123",
                filename: "Opened.md", description: "Note", text: "as published",
                baseContent: "as published", baseRevision: "one",
                stateData: try JSONEncoder().encode(PublishState.savedLocally)))
            context.insert(RetiredSchema.StoredDraft(
                id: UUID(), accountID: account, githubUserID: 42, gistID: "daily",
                filename: "2026-11-06.md", description: DailyNote.gistDescription, text: "# 2026-11-06\n\n",
                baseContent: nil, baseRevision: "one",
                stateData: try JSONEncoder().encode(PublishState.savedLocally)))
            context.insert(RetiredSchema.StoredRecovery(
                draft: draft, sent: "older source", generation: 6, remote: "remote base"
            ))
            context.insert(RetiredSchema.StoredCommandReceipt(id: UUID(), payload: Data("{}".utf8)))
            try context.save()
        }
        let upgraded = try DraftStore.open(url: url)
        #expect(try await upgraded.drafts(accountID: account).map(\.id) == [id])
        let draft = try #require(try await upgraded.draft(id: id, accountID: account))
        #expect(draft.text == "unsynced source")
        #expect(draft.generation == 7)
        #expect(draft.state == .savedLocally)
        #expect(draft.base == "remote base")
        try await upgraded.cacheGists(
            owned: [], starred: [], accountID: account
        )
        #expect(try await upgraded.apply(DraftEdit(draft: draft, text: " accepted")).text
            == "unsynced source accepted")
        #expect(try await upgraded.gistCache(accountID: account) != nil)
    }
}

// The persisted schema before recovery history, the autosave pause and command receipts were removed.
// It exists only so the test can prove those stores still open with their drafts intact.
enum RetiredSchema {
    @Model
    final class StoredDraft {
        @Attribute(.unique) var id: UUID
        var accountID: UUID
        var githubUserID: Int64
        var gistID: String?
        var filename: String
        var gistDescription: String
        var text: String
        var generation: UInt64
        var baseContent: String?
        var baseRevision: String?
        var attemptedContent: String?
        var attemptedGeneration: UInt64?
        var autosavePaused: Bool = false
        var stateData: Data
        var updatedAt: Date? = nil

        init(
            id: UUID, accountID: UUID, githubUserID: Int64, gistID: String?,
            filename: String, description: String, text: String, baseContent: String?,
            baseRevision: String?, stateData: Data
        ) {
            self.id = id
            self.accountID = accountID
            self.githubUserID = githubUserID
            self.gistID = gistID
            self.filename = filename
            gistDescription = description
            self.text = text
            generation = 0
            self.baseContent = baseContent
            self.baseRevision = baseRevision
            self.stateData = stateData
            updatedAt = .now
        }
    }

    @Model
    final class StoredRecovery {
        @Attribute(.unique) var id: UUID
        var accountID: UUID
        var draftID: UUID
        var createdAt: Date
        var base: String?
        var local: String
        var remote: String?
        var sent: String
        var generation: UInt64

        init(draft: StoredDraft, sent: String, generation: UInt64, remote: String?) {
            id = UUID()
            accountID = draft.accountID
            draftID = draft.id
            createdAt = .now
            base = draft.baseContent
            local = draft.text
            self.remote = remote
            self.sent = sent
            self.generation = generation
        }
    }

    @Model
    final class StoredCommandReceipt {
        @Attribute(.unique) var id: UUID
        var payload: Data

        init(id: UUID, payload: Data) {
            self.id = id
            self.payload = payload
        }
    }
}
