import Foundation
import Testing
@testable import Sync

private func dailyData() throws -> Data {
    try gistData(id: "abc123", description: DailyNote.gistDescription)
}

/// Adding to today, and the dates and tasks that follow the web.
@Suite struct DailyNotesTests {
    @Test func addToTodayAppendsAParagraphOrOneTaskPerLine() async throws {
        let store = try DraftStore.open(inMemory: true)
        var draft = try await store.newGistDraft(accountID: UUID(), githubUserID: 42, content: "# Today\n\nA thought")
        draft = try await store.apply(.addToToday("A second thought", asTask: false, to: draft))
        draft = try await store.apply(.addToToday("First task\n  \t\n日本語 👩🏽‍💻\n", asTask: true, to: draft))
        #expect(draft.text == "# Today\n\nA thought\n\nA second thought\n- [ ] First task\n- [ ] 日本語 👩🏽‍💻\n")
    }

    @Test func aDayWrittenOfflineJoinsTheDailyNotesGistTheWebStarted() async throws {
        let fixture = try SyncFixture()
        try await fixture.store.cacheLibrary(
            owned: [], starred: [], preferences: .init(metadata: [:]), accountID: SyncFixture.account)
        fixture.server.intercept { _ in throw URLError(.notConnectedToInternet) }
        let web = fixture.server.addGist(description: DailyNote.gistDescription, files: ["2020-01-01.md": "An old day"])
        let day = DailyNote.Day(date: .now, timeZone: .gmt)
        let today = try await DailyNotes(
            accountID: SyncFixture.account, githubUserID: SyncFixture.user, client: fixture.github,
            store: fixture.store, publisher: fixture.publisher
        ).stageToday(target: day).draft
        let typed = try await fixture.type("Written offline", in: today)
        fixture.server.intercept(nil)

        #expect(try await fixture.publish(typed).state == .savedToGitHub)
        #expect(fixture.server.gists.filter(\.isDailyNote).map(\.id) == [web.id])
        let files = try #require(fixture.server.gists.first { $0.id == web.id }).files
        #expect(files[day.filename]?.content == "Written offline")
        #expect(files["2020-01-01.md"]?.content == "An old day")
    }

    @Test func todayAndItsTasksFollowTheWeb() throws {
        let instant = try Date.ISO8601FormatStyle().parse("2026-10-24T01:00:00Z")
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(DailyNote.Day(date: instant, timeZone: la).filename == "2026-10-23.md")
        #expect(DailyNote.Day(date: instant, timeZone: utc).filename == "2026-10-24.md")
        #expect(DailyNote.date(filename: "2026-02-30.md") == nil)

        let markdown = "🌅 - [ ] Wake up \r\n- [x] Done\n- [X] Shouting\n```\n- [ ] Fenced\n```"
        let tasks = FileTask.tasks(in: markdown)
        #expect(tasks.map(\.title) == ["Wake up", "Done", "Fenced"])
        #expect(tasks.map(\.isChecked) == [false, true, false])
        #expect(tasks[0].markerRange == NSRange(location: 5, length: 3))
        #expect((markdown as NSString).substring(with: tasks[0].lineRange) == "🌅 - [ ] Wake up ")
        #expect((markdown as NSString).substring(with: tasks[1].markerRange) == "[x]")
        #expect(TaskProgress(markdown: markdown) == TaskProgress(completed: 1, total: 3))

        let day = DailyNote.Day(date: instant, timeZone: utc)
        let cache = { (truncated: Bool) in
            var object = try #require(try JSONSerialization.jsonObject(with: dailyData()) as? [String: Any])
            object["files"] = [day.filename: [
                "filename": day.filename, "language": "Markdown", "content": "- [ ] Partial", "truncated": truncated]]
            return CachedLibrary(
                accountID: UUID(), owned: [try decodeGist(JSONSerialization.data(withJSONObject: object))],
                starred: [], preferences: Preferences(metadata: [:]))
        }
        #expect(DailyNote(day: day, cache: try cache(true), drafts: []).progress == nil)
        let today = DailyNote(day: day, cache: try cache(false), drafts: [])
        #expect(today.gistID == "abc123")
        #expect(today.progress?.remaining == 1)
        #expect(today.date == DailyNote.date(filename: day.filename, timeZone: utc))
        #expect(DailyNote(day: day, cache: nil, drafts: []).progress == nil)
        #expect(DailyNote.content(template: nil, filename: "2026-10-24.md")
            == "# 2026-10-24\n\n")
        #expect(DailyNote.content(
            template: GistFile.emptyContent, filename: "2026-10-24.md"
        ) == "")
    }
}
