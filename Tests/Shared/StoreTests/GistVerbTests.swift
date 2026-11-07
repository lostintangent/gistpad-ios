import Foundation
import Testing
@testable import Store

/// Renaming, deleting and dating your files, on the phone and on GitHub.
@Suite struct GistVerbTests {
    private let account = SyncFixture.account

    @Test func renamingADraftKeepsWhatYouTyped() async throws {
        let sync = try SyncFixture()
        let gist = sync.server.addGist(description: "Before", files: ["One.md": "one", "Two.md": "two"])
        let one = try await sync.type("local", in: sync.open(gist, "One.md"))

        let renamed = try await sync.store.rename(one, filename: "New.md")
        #expect(renamed == one.renamed("New.md"))
        #expect(try await sync.store.current(GistFileDraft(
            accountID: account, gist: gist, filename: "New.md", text: "remote"))?.id == one.id)
    }

    @Test func aFilesEditTimeIsWhenYouTyped() async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sync = try SyncFixture(store: GistFileDraftStore.open(url: url))
        let gist = sync.server.addGist(description: "Note", files: ["Caf\u{e9}.md": "base"])
        let opened = try await sync.open(gist, "Caf\u{e9}.md")

        let edited = try await sync.type("edit", in: opened)
        #expect(edited.editedAt > opened.editedAt)
        let same = try await sync.type("edit", in: opened)
        #expect(same.editedAt == edited.editedAt)
        #expect(try await GistFileDraftStore.open(url: url).draft(id: opened.id, accountID: account)?.editedAt
            == edited.editedAt)
    }
}
