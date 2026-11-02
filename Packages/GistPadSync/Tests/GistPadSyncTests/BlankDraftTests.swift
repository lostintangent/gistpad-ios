import Foundation
import Testing
@testable import GistPadSync

/// A new note you never typed in disappears when you leave it. Anything you touched stays.
@Suite struct BlankDraftTests {
    private let account = SyncFixture.account

    @Test(arguments: [false, true])
    func anUntouchedDailyTemplateIsDiscardedButItsGistStays(gistExists: Bool) async throws {
        let sync = try SyncFixture()
        let daily = gistExists ? sync.server.addGist(
            description: DailyNote.gistDescription, files: ["2026-10-01.md": "Keep yesterday."]) : nil
        let today = DailyNote.Day(date: try Date.ISO8601FormatStyle().parse("2026-10-24T12:00:00Z"), timeZone: .gmt)

        let untouched = try await sync.dailyNotes.stageToday(target: today).draft
        #expect(untouched.isDiscardableBlank)
        #expect(try await sync.store.discardBlankDraft(
            id: untouched.id, accountID: account, expectedGeneration: untouched.generation))
        #expect(try await sync.store.drafts(accountID: account).isEmpty)
        #expect(sync.server.gists.map(\.id) == [daily?.id].compactMap { $0 })
        #expect(sync.remote(daily?.id ?? "", "2026-10-01.md") == daily.map { _ in "Keep yesterday." })

        // Typing, even the same text, keeps the day, and so does publishing it or a custom template.
        let staged = try await sync.dailyNotes.stageToday(target: today).draft
        let touched = try await sync.type(staged.text, in: staged)
        let published = try await sync.publish(touched)
        let custom = try await sync.store.newGistDraft(
            accountID: account, githubUserID: SyncFixture.user, filename: "2026-10-25.md",
            description: DailyNote.gistDescription, content: "- [ ] A custom template")
        for kept in [touched, published, custom] {
            #expect(!kept.isDiscardableBlank)
            #expect(try await !sync.store.discardBlankDraft(
                id: kept.id, accountID: account, expectedGeneration: kept.generation))
        }
        #expect(sync.server.gists.count == 1)
    }

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
