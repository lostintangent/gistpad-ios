import Foundation
import GistPadComments
import Testing
@testable import GistPadSync

struct CommentConversationDiskStoreTests {
    @Test func confirmedGistDeletionRemovesOnlyItsAccountScopedComposerArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommentConversationDiskStore(directory: directory)
        let scope = CommentConversationScope(accountID: UUID(), gistID: "a123")
        let otherAccount = CommentConversationScope(accountID: UUID(), gistID: "a123")
        let otherGist = CommentConversationScope(accountID: scope.accountID, gistID: "b456")
        for item in [scope, otherAccount, otherGist] {
            try await store.saveDrafts(CommentDraftArchive(scope: item))
        }
        try await store.removeDrafts(scope: scope)
        try await store.removeDrafts(scope: scope)
        #expect(try await store.loadDrafts(scope: scope) == nil)
        #expect(try await store.loadDrafts(scope: otherAccount) != nil)
        #expect(try await store.loadDrafts(scope: otherGist) != nil)
        await #expect(throws: CommentStoreFailure.unavailable) {
            try await store.saveDrafts(CommentDraftArchive(scope: scope))
        }
        #expect(try await CommentConversationDiskStore(directory: directory).loadDrafts(scope: scope) == nil)
    }

    @Test func copyingCommentCountPreservesAllOtherGistBytes() throws {
        let data = Data("""
            {"id":"a123","description":"Synthetic [Archived]","public":false,
             "files":{"README.md":{"filename":"README.md","language":"Markdown",
               "content":"Cafe\\u0301","truncated":false,"size":6}},
             "owner":{"id":7,"login":"author","avatar_url":"https://example.com/avatar"},
             "created_at":"2026-10-23T12:00:00Z","updated_at":"2026-10-24T12:00:00Z",
             "truncated":false,"history":[{"version":"revision"}],"comments":2}
            """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let original = try decoder.decode(Gist.self, from: data)
        let updated = original.withCommentCount(9)
        #expect(updated.commentCount == 9)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(updated.withCommentCount(original.commentCount)) == encoder.encode(original))
    }

    @Test func restoresDraftAndPendingIntentAcrossStoreInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = CommentConversationScope(accountID: UUID(), gistID: "a123")
        var archive = CommentDraftArchive(scope: scope)
        archive.drafts[0].text = "Cafe\u{301}\nA durable draft"
        archive.revision = 4
        archive.pendingMutation = PendingCommentMutation(
            operation: .create(body: archive.drafts[0].text),
            draftID: archive.activeDraftID, draftGeneration: 0,
            baselineIDs: [9, 2, 7], authorID: 42)
        let store = CommentConversationDiskStore(directory: directory)
        try await store.saveDrafts(archive)
        let restored = try #require(
            await CommentConversationDiskStore(directory: directory).loadDrafts(scope: scope))
        #expect(restored == archive)
        #expect(restored.drafts[0].text.utf8.elementsEqual(archive.drafts[0].text.utf8))
        try await store.saveDrafts(restored)
    }

    @Test func accountsAndGistsCannotReadEachOthersDrafts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommentConversationDiskStore(directory: directory)
        let accountID = UUID()
        let scope = CommentConversationScope(accountID: accountID, gistID: "a123")
        try await store.saveDrafts(CommentDraftArchive(scope: scope))
        #expect(try await store.loadDrafts(scope: .init(accountID: UUID(), gistID: "a123")) == nil)
        #expect(try await store.loadDrafts(scope: .init(accountID: accountID, gistID: "b456")) == nil)
    }

    @Test func olderWritesAndEqualGenerationByteChangesAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommentConversationDiskStore(directory: directory)
        let scope = CommentConversationScope(accountID: UUID(), gistID: "a123")
        var first = CommentDraftArchive(scope: scope)
        first.revision = 2
        first.drafts[0].text = "Cafe\u{301}"
        try await store.saveDrafts(first)
        var older = first
        older.revision = 1
        await #expect(throws: CommentStoreFailure.staleWrite) { try await store.saveDrafts(older) }
        var composed = first
        composed.drafts[0].text = "Caf\u{e9}"
        await #expect(throws: CommentStoreFailure.staleWrite) { try await store.saveDrafts(composed) }
        let saved = try #require(await store.loadDrafts(scope: scope))
        #expect(saved.drafts[0].text.utf8.elementsEqual(first.drafts[0].text.utf8))
    }

    @Test func corruptDraftBytesAreAnErrorNotAnEmptyDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommentConversationDiskStore(directory: directory)
        let scope = CommentConversationScope(accountID: UUID(), gistID: "a123")
        try await store.saveDrafts(CommentDraftArchive(scope: scope))
        let file = directory.appendingPathComponent(scope.accountID.uuidString)
            .appendingPathComponent(scope.gistID).appendingPathComponent("drafts.json")
        try Data("not a draft archive".utf8).write(to: file, options: .atomic)
        await #expect(throws: DecodingError.self) { try await store.loadDrafts(scope: scope) }
    }

    @Test func pathComponentsAreValidatedBeforeAccess() async {
        let store = CommentConversationDiskStore(directory: FileManager.default.temporaryDirectory)
        await #expect(throws: CommentStoreFailure.invalidRecord) {
            try await store.loadDrafts(scope: .init(accountID: UUID(), gistID: "../other"))
        }
    }
}
