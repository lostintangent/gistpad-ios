import Foundation
import SwiftData
import Testing
@testable import GistPadSync

@Suite struct SharedStoreTests {
    @Test func invalidUTF16OffsetsAndStaleGenerationsNeverMutateTheDraft() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let text = "\u{1F642} - [ ] Task"
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: text)
        let splitSurrogate = SharedDraftCommand(
            accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: DraftSourceEdit(location: 1, length: 0, expectedText: "", replacement: "broken")
        )
        await #expect(throws: SharedStoreError.invalidCommand) { try await store.apply(splitSurrogate) }
        let stale = SharedDraftCommand(
            accountID: account, draftID: draft.id, expectedGeneration: 3,
            edit: DraftSourceEdit(location: 6, length: 1, expectedText: " ", replacement: "x")
        )
        await #expect(throws: DraftError.staleGeneration) { try await store.apply(stale) }
        #expect(try await store.draft(id: draft.id, accountID: account).text == text)
    }

    @Test func schemaExpansionKeepsDraftsAndDropsRetiredRecoveryRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let id = UUID()
        do {
            let schema = Schema([Build16Schema.StoredDraft.self, Build16Schema.StoredRecovery.self])
            let configuration = ModelConfiguration("GistPadDrafts", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let draft = Build16Schema.StoredDraft(
                id: id, accountID: account, githubUserID: 42, gistID: "abc123",
                filename: "README.md", description: "Note", text: "unsynced source",
                baseContent: "remote base", baseRevision: "one",
                stateData: try JSONEncoder().encode(PublishState.savedLocally)
            )
            draft.generation = 7
            draft.autosavePaused = true
            context.insert(draft)
            context.insert(Build16Schema.StoredRecovery(
                draft: draft, sent: "older source", generation: 6, remote: "remote base"
            ))
            try context.save()
        }
        let upgraded = try DraftStore.open(url: url)
        let draft = try await upgraded.draft(id: id, accountID: account)
        #expect(draft.text == "unsynced source")
        #expect(draft.generation == 7)
        #expect(draft.state == .savedLocally)
        #expect(draft.baseContent == "remote base")
        try await upgraded.cacheLibrary(
            owned: [], starred: [], preferences: Preferences(metadata: [:]), accountID: account
        )
        let command = SharedDraftCommand(
            accountID: account, draftID: id, expectedGeneration: 7,
            edit: DraftSourceEdit(location: 0, length: 8, expectedText: "unsynced", replacement: "accepted")
        )
        #expect(try await upgraded.apply(command).text == "accepted source")
        #expect(try await upgraded.cachedLibrary(accountID: account) != nil)
    }
}

// Build 16's persisted schema. It exists only so the test can prove that stores written before the
// recovery and autosave-pause removal still open with their drafts intact.
enum Build16Schema {
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
}
