import Foundation
import Testing
@testable import GistPadSync

/// A new gist you never titled or typed in disappears when you leave it. Anything you touched stays.
@Suite struct BlankDraftTests {
    private let account = SyncFixture.account

    @Test func onlyAStillBlankNewFileIsDiscarded() async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DraftStore.open(url: url)
        let user = SyncFixture.user
        var blanks = [
            try await store.newDraft(accountID: account, githubUserID: user),
            try await store.newDraft(accountID: account, githubUserID: user, text: " \t\r\n\u{2003}"),
        ]
        var kept = [
            try await store.newDraft(accountID: account, githubUserID: user, description: "A title"),
            try await store.draft(
                accountID: account, githubUserID: user, gistID: "existing", filename: "README.md",
                description: "", content: "", revision: "one"),
        ]
        for text in ["\u{2064}", "👩🏽‍💻", "\u{200B}", "Keep e\u{301}\r\n日本語"] {
            kept.append(try await store.newDraft(accountID: account, githubUserID: user, text: text))
        }
        let retyped = try await store.newDraft(accountID: account, githubUserID: user)
        blanks.append(try await store.persist(id: retyped.id, accountID: account, text: " ", generation: 1))

        for draft in kept {
            #expect(!draft.isDiscardableBlank)
            #expect(try await !store.discardBlankDraft(
                id: draft.id, accountID: account, expectedGeneration: draft.generation))
        }
        #expect(try await !store.discardBlankDraft(id: retyped.id, accountID: account, expectedGeneration: 0))
        await #expect(throws: DraftError.accountMismatch) {
            try await store.discardBlankDraft(id: retyped.id, accountID: UUID(), expectedGeneration: 1)
        }
        let reopened = try DraftStore.open(url: url)
        for draft in blanks {
            #expect(try await reopened.discardBlankDraft(
                id: draft.id, accountID: account, expectedGeneration: draft.generation))
        }
        let remaining = try await DraftStore.open(url: url).drafts(accountID: account)
        #expect(Set(remaining.map(\.id)) == Set(kept.map(\.id)))
        #expect(remaining.map(\.text).sorted() == kept.map(\.text).sorted())
    }
}
