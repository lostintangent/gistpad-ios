import Foundation
import Testing
@testable import Sync

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
        await #expect(throws: DraftError.staleGeneration) { try await rename("Gone.md", to: "Three.md") }
        await #expect(throws: DraftError.accountMismatch) { try await rename("One.md", to: "Three.md", account: UUID()) }
        for filename in ["", "folder/file.md", "bad\nname.md"] {
            await #expect(throws: DraftError.invalidFilename) { try await rename("One.md", to: filename) }
        }
        try await sync.store.recordSent(id: one.id, accountID: account, content: "local", generation: 1)
        await #expect(throws: DraftError.publicationPending) { try await rename("One.md", to: "New.md") }
        try await sync.store.forgetSent(id: one.id, accountID: account)

        let renamed = try await rename("One.md", to: "New.md")
        #expect(renamed.filename == "New.md")
        #expect(renamed.description == "After")
        #expect(renamed.text == one.text)
        #expect(renamed.generation == one.generation)
        #expect(renamed.base == one.base)
        #expect(renamed.baseRevision == one.baseRevision)
        #expect(renamed.state == one.state)
        #expect(try await sync.store.draft(
            accountID: account, githubUserID: SyncFixture.user, gistID: gist.id, filename: "New.md",
            description: "After", content: "remote", revision: "two").id == one.id)
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
