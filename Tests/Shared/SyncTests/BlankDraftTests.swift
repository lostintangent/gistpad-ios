import Foundation
import Testing
@testable import Sync

/// A new gist you never titled or typed in, or a day you opened and never typed in, disappears when
/// you leave it. Anything you touched stays.
@Suite struct BlankDraftTests {
    private let account = SyncFixture.account

    enum DayStart: CaseIterable { case firstDay, heading, template }

    @Test(arguments: DayStart.allCases)
    func anUntouchedDayIsDiscardedButItsGistStays(_ start: DayStart) async throws {
        let sync = try SyncFixture()
        var files = ["2026-10-23.md": "Keep yesterday."]
        if start == .template { files["template.md"] = "# {{date}}\n\n- [ ] Plan\n" }
        let daily = start == .firstDay
            ? nil : sync.server.addGist(description: DailyNote.gistDescription, files: files)
        // The cache holds the daily gist as a publish leaves it, with its revision.
        try await sync.store.cacheLibrary(
            owned: [daily].compactMap { $0 }, starred: [], preferences: .init(metadata: [:]),
            accountID: account)
        let today = DailyNote.Day(
            date: try Date.ISO8601FormatStyle().parse("2026-10-24T12:00:00Z"), timeZone: .gmt)

        let untouched = try await sync.dailyNotes.stageToday(target: today).draft
        #expect(untouched.text.hasPrefix("# 2026-10-24\n\n"))
        #expect(untouched.isDiscardableBlank)
        #expect(!untouched.hasUnpublishedEdits)
        #expect(try await sync.store.discardBlankDraft(
            id: untouched.id, accountID: account, expectedGeneration: untouched.generation))
        #expect(try await sync.store.drafts(accountID: account).isEmpty)
        #expect(sync.server.gists.map(\.id) == [daily?.id].compactMap { $0 })
        #expect(sync.remote(daily?.id ?? "", today.filename) == nil)

        // Typing, even the same text, keeps the day, and so does publishing it.
        let staged = try await sync.dailyNotes.stageToday(target: today).draft
        let touched = try await sync.type(staged.text, in: staged)
        let published = try await sync.publish(touched)
        for kept in [touched, published] {
            #expect(!kept.isDiscardableBlank)
            #expect(try await !sync.store.discardBlankDraft(
                id: kept.id, accountID: account, expectedGeneration: kept.generation))
        }
        let gist = try #require(sync.server.gists.first { $0.isDailyNote })
        #expect(sync.remote(gist.id, today.filename) == staged.text)
        #expect(sync.remote(gist.id, "2026-10-23.md") == daily.map { _ in "Keep yesterday." })
    }

    @Test func onlyAStillBlankNewFileIsDiscarded() async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DraftStore.open(url: url)
        let user = SyncFixture.user
        var blanks = [
            try await store.newGistDraft(accountID: account, githubUserID: user),
            try await store.newGistDraft(accountID: account, githubUserID: user, content: " \t\r\n\u{2003}"),
        ]
        let titled = try await store.newGistDraft(accountID: account, githubUserID: user, description: "A title")
        var kept = [
            try await store.persist(id: titled.id, accountID: account, text: "", generation: 1),
            try await store.draft(
                accountID: account, githubUserID: user, gistID: "existing", filename: "README.md",
                description: "", content: "", revision: "one"),
        ]
        for text in ["\u{2064}", "👩🏽‍💻", "\u{200B}", "Keep e\u{301}\r\n日本語"] {
            let typed = try await store.newGistDraft(accountID: account, githubUserID: user)
            kept.append(try await store.persist(id: typed.id, accountID: account, text: text, generation: 1))
        }
        let retyped = try await store.newGistDraft(accountID: account, githubUserID: user)
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
