import Foundation
import Testing
@testable import GistPadSync

/// Renaming, deleting and dating your files, on the phone and on GitHub.
@Suite struct GistVerbTests {
    private let account = SyncFixture.account

    @Test func metadataChangesRetainSourceAndGeneration() async throws {
        let sync = try SyncFixture()
        let gist = sync.server.addGist(description: "Before", files: ["One.md": "one", "Two.md": "two"])
        let one = try await sync.type("local", in: sync.open(gist, "One.md"))
        _ = try await sync.open(gist, "Two.md")
        func rename(_ expected: String, to filename: String, account: UUID = SyncFixture.account) async throws
            -> Draft {
            try await sync.store.updateDraftMetadata(
                id: one.id, accountID: account, expectedFilename: expected, filename: filename, description: "After")
        }

        await #expect(throws: DraftError.filenameInUse) { try await rename("One.md", to: "Two.md") }
        await #expect(throws: DraftError.staleMetadata) { try await rename("Gone.md", to: "Three.md") }
        await #expect(throws: DraftError.accountMismatch) { try await rename("One.md", to: "Three.md", account: UUID()) }
        for filename in ["", "folder/file.md", "bad\nname.md"] {
            await #expect(throws: DraftError.invalidFilename) { try await rename("One.md", to: filename) }
        }
        try await sync.store.beginAttempt(id: one.id, accountID: account, content: "local", generation: 1)
        await #expect(throws: DraftError.publicationPending) { try await rename("One.md", to: "New.md") }
        try await sync.store.clearAttempt(id: one.id, accountID: account)

        let renamed = try await rename("One.md", to: "New.md")
        #expect(renamed.filename == "New.md")
        #expect(renamed.description == "After")
        #expect(renamed.text == one.text)
        #expect(renamed.generation == one.generation)
        #expect(renamed.baseContent == one.baseContent)
        #expect(renamed.baseRevision == one.baseRevision)
        #expect(renamed.state == one.state)
        #expect(try await sync.store.draft(
            accountID: account, githubUserID: SyncFixture.user, gistID: gist.id, filename: "New.md",
            description: "After", content: "remote", revision: "two").id == one.id)
    }

    @Test func deletingAGistPurgesItsDraftsAndCachedCopies() async throws {
        let sync = try SyncFixture()
        let doomed = sync.server.addGist(description: "Doomed", files: ["Clean.md": "base", "Dirty.md": "base"])
        let kept = sync.server.addGist(description: "Kept", files: ["README.md": "untouched"])
        let clean = try await sync.open(doomed, "Clean.md")
        let dirty = try await sync.type("unsynced", in: sync.open(doomed, "Dirty.md"))
        let keptDraft = try await sync.type("kept", in: sync.open(kept))
        let otherAccount = UUID()
        let foreign = try await sync.store.draft(
            accountID: otherAccount, githubUserID: 9, gistID: doomed.id, filename: "Clean.md",
            description: "Doomed", content: "base", revision: "one")
        let listed = try await sync.github.listGists()
        try await sync.store.cacheLibrary(
            owned: listed, starred: listed, preferences: .init(metadata: [:]), accountID: account)
        for gist in [doomed, kept] {
            let full = try await sync.github.gist(id: gist.id)
            try await sync.store.cacheGist(full, accountID: account)
            try await sync.store.cacheContent("cached", gist: full, filename: full.files.keys.sorted()[0], accountID: account)
        }

        try await sync.github.deleteGist(id: doomed.id)
        try await sync.store.removeDrafts(gistID: doomed.id, accountID: account)
        #expect(sync.server.gists.map(\.id) == [kept.id])
        let drafts = try await sync.store.drafts(accountID: account)
        #expect(drafts.map(\.id) == [keptDraft.id])
        #expect(!drafts.contains { [clean.id, dirty.id].contains($0.id) })
        #expect(try await sync.store.draft(id: foreign.id, accountID: otherAccount).text == "base")
        let cached = try #require(await sync.store.cachedLibrary(accountID: account))
        #expect(cached.owned.map(\.id) == [kept.id])
        #expect(cached.starred.map(\.id) == [kept.id])
        #expect(Set(cached.details.keys) == [kept.id])
        #expect(Array(cached.fileContent.keys) == ["\(kept.id)/README.md"])
    }

    @Test func deletedFileDropsOnlyItsOwnDraftsAndKeepsTheRestOfTheGist() async throws {
        let sync = try SyncFixture()
        let gist = sync.server.addGist(
            description: DailyNote.gistDescription,
            files: ["2026-10-23.md": "yesterday", "2026-10-24.md": "today"])
        _ = try await sync.type("unsynced", in: sync.open(gist, "2026-10-24.md"))
        let sibling = try await sync.open(gist, "2026-10-23.md")
        let before = try await sync.github.gist(id: gist.id)
        try await sync.store.cacheLibrary(
            owned: sync.github.listGists(), starred: [], preferences: .init(metadata: [:]), accountID: account)
        try await sync.store.cacheGist(before, accountID: account)
        try await sync.store.cacheContent("today", gist: before, filename: "2026-10-24.md", accountID: account)

        let updated = try await sync.github.updateGist(id: gist.id, files: ["2026-10-24.md": .delete])
        try await sync.store.removeDrafts(
            gistID: gist.id, filename: "2026-10-24.md", updated: updated, accountID: account)
        #expect(sync.remote(gist.id, "2026-10-24.md") == nil)
        #expect(sync.remote(gist.id, "2026-10-23.md") == "yesterday")
        #expect(try await sync.store.drafts(accountID: account).map(\.id) == [sibling.id])
        let cached = try #require(await sync.store.cachedLibrary(accountID: account))
        #expect(cached.owned.first?.files.keys.sorted() == ["2026-10-23.md"])
        #expect(cached.details[gist.id]?.files["2026-10-24.md"] == nil)
        #expect(cached.fileContent["\(gist.id)/2026-10-24.md"] == nil)
    }

    @Test func aPhoneOnlyGistCanBeDeleted() async throws {
        let sync = try SyncFixture()
        let local = try await sync.store.newGistDraft(
            accountID: account, githubUserID: SyncFixture.user, content: "Only on this iPhone")
        let edited = try await sync.type("Edited only on this iPhone", in: local)
        await #expect(throws: DraftError.staleGeneration) {
            try await sync.store.discardLocalCopy(id: local.id, accountID: account, expectedGeneration: 0)
        }
        try await sync.store.discardLocalCopy(id: local.id, accountID: account, expectedGeneration: edited.generation)
        #expect(try await sync.store.drafts(accountID: account).isEmpty)
        #expect(sync.server.requests.isEmpty)
    }

    @Test func aFilesEditTimeIsWhenYouTyped() async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sync = try SyncFixture(store: DraftStore.open(url: url))
        let gist = sync.server.addGist(description: "Note", files: ["Caf\u{e9}.md": "base"])
        let opened = try await sync.open(gist, "Caf\u{e9}.md")

        let edited = try await sync.type("edit", in: opened)
        #expect(edited.updatedAt != nil)
        #expect(edited.updatedAt != opened.updatedAt)
        let same = try await sync.store.persist(id: opened.id, accountID: account, text: "edit", generation: 1)
        #expect(same.updatedAt == edited.updatedAt)
        let published = try await sync.publish(edited)
        #expect(published.updatedAt == edited.updatedAt)
        #expect(try await DraftStore.open(url: url).draft(id: opened.id, accountID: account).updatedAt
            == edited.updatedAt)

        // A rename to canonically equal but byte-distinct Unicode is still an edit.
        let renamed = try await sync.store.updateDraftMetadata(
            id: opened.id, accountID: account, expectedFilename: opened.filename,
            filename: "Cafe\u{301}.md", description: "Note")
        #expect(renamed.filename.utf8.elementsEqual("Cafe\u{301}.md".utf8))
        #expect(renamed.updatedAt != edited.updatedAt)
        let unchanged = try await sync.store.updateDraftMetadata(
            id: opened.id, accountID: account, expectedFilename: renamed.filename,
            filename: renamed.filename, description: "Note")
        #expect(unchanged.updatedAt == renamed.updatedAt)
    }
}
