import Foundation
import Testing
@testable import Sync

/// Renaming, deleting and dating your files, on the phone and on GitHub.
@Suite struct GistVerbTests {
    private let account = SyncFixture.account

    @Test func renamingADraftKeepsWhatYouTyped() async throws {
        let sync = try SyncFixture()
        let gist = sync.server.addGist(description: "Before", files: ["One.md": "one", "Two.md": "two"])
        let one = try await sync.type("local", in: sync.open(gist, "One.md"))

        let renamed = try await sync.store.rename(
            one.id, accountID: account, filename: "New.md", description: "After")
        #expect(renamed.filename == "New.md")
        #expect(renamed.description == "After")
        #expect(renamed.text == one.text)
        #expect(renamed.generation == one.generation)
        #expect(renamed.base == one.base)
        #expect(renamed.baseRevision == one.baseRevision)
        #expect(renamed.state == one.state)
        #expect(try await sync.store.current(Draft(
            accountID: account, githubUserID: SyncFixture.user, gist: gist, filename: "New.md",
            text: "remote")).id == one.id)
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
        let same = try await sync.store.save(opened, text: "edit", generation: 1)
        #expect(same.updatedAt == edited.updatedAt)
        #expect(try await DraftStore.open(url: url).draft(id: opened.id, accountID: account)?.updatedAt
            == edited.updatedAt)
    }
}
