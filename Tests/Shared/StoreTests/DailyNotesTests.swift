import Foundation
import Testing
@testable import Store

private func dailyData() throws -> Data {
    try gistData(id: "abc123", description: DailyNote.gistDescription)
}

/// Adding to today, and the dates and tasks that follow the web.
@Suite struct DailyNotesTests {
    @Test func addToTodayAppendsAParagraphOrOneTaskPerLine() async throws {
        let store = try DraftStore.open(inMemory: true)
        var draft = Draft(accountID: UUID(), githubUserID: 42, text: "# Today\n\nA thought")
        draft = try await store.apply(.addToToday("A second thought", asTask: false, to: draft))
        draft = try await store.apply(.addToToday("First task\n  \t\n日本語 👩🏽‍💻\n", asTask: true, to: draft))
        #expect(draft.text == "# Today\n\nA thought\n\nA second thought\n- [ ] First task\n- [ ] 日本語 👩🏽‍💻\n")
    }

    /// When the web wrote the same day too, the publish shows the conflict instead of overwriting it,
    /// and Today still finds your day in the web's gist.
    @Test(arguments: [false, true])
    func aDayWrittenOfflineJoinsTheDailyNotesGistTheWebStarted(webWroteToday: Bool) async throws {
        let fixture = try SyncFixture()
        try await fixture.store.cacheGists(
            owned: [], starred: [], accountID: SyncFixture.account)
        fixture.server.intercept { _ in throw URLError(.notConnectedToInternet) }
        let day = DailyNote.Day(date: .now, timeZone: .gmt)
        var webFiles = ["2020-01-01.md": "An old day"]
        if webWroteToday { webFiles[day.filename] = "Written on the web" }
        let web = fixture.server.addGist(description: DailyNote.gistDescription, files: webFiles)
        let today = try await DailyNotes(
            accountID: SyncFixture.account, githubUserID: SyncFixture.user, client: fixture.github,
            store: fixture.store
        ).stageToday(target: day).draft
        let typed = try await fixture.type("Written offline", in: today)
        fixture.server.intercept(nil)

        let published = try await fixture.publish(typed)
        if webWroteToday {
            #expect(published.state == .conflict(.init(
                generation: typed.generation, base: nil, local: "Written offline",
                remote: "Written on the web", remoteRevision: web.revision)))
        } else {
            #expect(published.state == .savedToGitHub)
        }
        #expect(fixture.server.gists.filter(\.isDailyNote).map(\.id) == [web.id])
        let files = try #require(fixture.server.gists.first { $0.id == web.id }).files
        #expect(files[day.filename]?.content == (webWroteToday ? "Written on the web" : "Written offline"))
        #expect(files["2020-01-01.md"]?.content == "An old day")
        let found = DailyNote(
            day: day, cache: try await fixture.store.gistCache(accountID: SyncFixture.account),
            drafts: try await fixture.store.drafts(accountID: SyncFixture.account))
        #expect(found.gistID == web.id && found.text == "Written offline")
        #expect(found.draftID == (webWroteToday ? typed.id : nil))
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
            return GistCache(
                accountID: UUID(), owned: [try decodeGist(JSONSerialization.data(withJSONObject: object))],
                starred: [])
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
            template: Gist.File.emptyContent, filename: "2026-10-24.md"
        ) == "")
    }
}
