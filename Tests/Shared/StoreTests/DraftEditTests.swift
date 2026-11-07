import Foundation
import SwiftData
import Testing
@testable import Store

@Suite struct DraftEditTests {
    @Test func aStaleAdditionNeverMutatesTheDraft() async throws {
        let store = try GistFileDraftStore.open(inMemory: true)
        let account = UUID()
        let text = "- [ ] Task"
        let opened = GistFileDraft(accountID: account)
        let typed = try await store.save(opened, text: text, github: nil)
        await #expect(throws: DraftError.changed) {
            try await store.apply(DraftEdit(draft: opened, text: "x"), github: nil)
        }
        #expect(try await store.draft(id: typed.id, accountID: account)?.text == text)
    }

    /// A publish can land between keystrokes, after the editor read the draft, so the next
    /// keystroke starts from what GitHub now has.
    @Test func aKeystrokeAfterAPublishStartsFromGitHubsText() async throws {
        let store = try GistFileDraftStore.open(inMemory: true)
        let older = GitHubVersion(text: "one", revision: "a")
        let opened = GistFileDraft(accountID: UUID(), gistID: "abc123", text: "one", base: older)
        let typed = try await store.save(opened, text: "one two", github: older)
        let published = GitHubVersion(text: "one two", revision: "b")
        #expect(try await store.confirm(typed, gistID: "abc123", base: published).isDisposable)

        let next = try await store.save(typed, text: "one two three", github: published)
        #expect(next.base == published)
    }

    /// Earlier builds stored a publish state, whose conflict still waits for you after an update.
    @Test func schemaChangesKeepDraftsAndTheirConflicts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let id = UUID()
        let conflicted = UUID()
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
                stateData: Data(#"{"savedLocally":{}}"#.utf8)
            )
            draft.generation = 7
            draft.autosavePaused = true
            context.insert(draft)
            context.insert(RetiredSchema.StoredDraft(
                id: conflicted, accountID: account, githubUserID: 42, gistID: "abc123",
                filename: "Other.md", description: "Note", text: "mine",
                baseContent: "base", baseRevision: "one",
                stateData: Data(#"{"conflict":{"_0":{"remote":"theirs","remoteRevision":"two"}}}"#.utf8)))
            context.insert(RetiredSchema.StoredRecovery(
                draft: draft, sent: "older source", generation: 6, remote: "remote base"
            ))
            context.insert(RetiredSchema.StoredCommandReceipt(id: UUID(), payload: Data("{}".utf8)))
            try context.save()
        }
        let upgraded = try GistFileDraftStore.open(url: url)
        let draft = try #require(try await upgraded.draft(id: id, accountID: account))
        #expect(draft.text == "unsynced source")
        #expect(draft.base == GitHubVersion(text: "remote base", revision: "one"))
        #expect(draft.conflict == nil)
        #expect(try await upgraded.draft(id: conflicted, accountID: account)?.conflict
            == GitHubVersion(text: "theirs", revision: "two"))
        try GistCache(accountID: account).save(to: upgraded.modelContainer)
        #expect(try await upgraded.apply(DraftEdit(draft: draft, text: " accepted"), github: nil).text
            == "unsynced source accepted")
        #expect(try GistCache.load(accountID: account, from: upgraded.modelContainer) != nil)
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
