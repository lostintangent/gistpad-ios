import Foundation
import Testing
@testable import GistPadSync

private func dailyData() throws -> Data {
    try gistData(id: "abc123", description: GistConventions.dailyNotesDescription)
}

private func day(_ iso: String) throws -> DailyNoteTarget {
    DailyNoteTarget(date: try Date.ISO8601FormatStyle().parse("\(iso)T12:00:00Z"), timeZone: .gmt)
}

/// Today's note, staged on the phone and published like any other file.
@Suite struct DailyNotesTests {
    @Test func openingTodayNeverPublishesAndKeepsYourTyping() async throws {
        let sync = try SyncFixture()
        let gist = sync.server.addGist(description: GistConventions.dailyNotesDescription, files: [
            "2026-10-23.md": "- [ ] Yesterday", "template.md": "# {{date}}\n\n- [ ] Plan {{date}}\n",
        ])
        let today = try day("2026-10-24")

        let staged = try await sync.dailyNotes.stageToday(target: today)
        #expect(staged.gist?.id == gist.id)
        #expect(staged.draft.gistID == gist.id)
        #expect(staged.draft.text == "# 2026-10-24\n\n- [ ] Plan 2026-10-24\n")
        let typed = try await sync.type("- [x] Plan", in: staged.draft)
        let again = try await sync.dailyNotes.stageToday(target: today)
        #expect(again.draft.id == typed.id)
        #expect(again.draft.text == "- [x] Plan")

        let yesterday = try await sync.dailyNotes.stageToday(target: day("2026-10-23"))
        #expect(yesterday.draft.text == "- [ ] Yesterday")
        #expect(yesterday.draft.state == .savedToGitHub)
        #expect(sync.server.requests.allSatisfy { $0.hasPrefix("GET ") })
        #expect(sync.remote(gist.id, today.filename) == nil)
    }

    @Test func theFirstTodayCreatesTheWebsDailyGist() async throws {
        let sync = try SyncFixture()
        let first = try day("2026-10-24"), second = try day("2026-10-25")

        let staged = try await sync.dailyNotes.stageToday(target: first)
        #expect(staged.gist == nil)
        #expect(staged.draft.gistID == nil)
        #expect(staged.draft.description == GistConventions.dailyNotesDescription)
        #expect(staged.draft.text == "# 2026-10-24\n\n")
        #expect(try await sync.dailyNotes.stageToday(target: first).draft.id == staged.draft.id)
        _ = try await sync.type("# 2026-10-24\n\n- [ ] Ship", in: staged.draft)
        #expect(sync.server.gists.isEmpty)

        // The next day publishes the unpublished one first, which creates the gist the new day joins.
        let next = try await sync.dailyNotes.stageToday(target: second)
        let gist = try #require(sync.server.gists.first)
        #expect(gist.isDailyNote)
        #expect(gist.isPublic == false)
        #expect(sync.remote(gist.id, first.filename) == "# 2026-10-24\n\n- [ ] Ship")
        #expect(next.gist?.id == gist.id)
        #expect(next.draft.gistID == gist.id)
        #expect(next.draft.text == "# 2026-10-25\n\n")
        #expect(sync.remote(gist.id, second.filename) == nil)

        #expect(try await sync.publish(next.draft).state == .savedToGitHub)
        #expect(sync.remote(gist.id, second.filename) == "# 2026-10-25\n\n")
        #expect(sync.server.gists.count == 1)
        #expect(sync.count("POST /gists") == 1)
    }

    @Test func todayAndItsTasksFollowTheWeb() throws {
        let instant = try Date.ISO8601FormatStyle().parse("2026-10-24T01:00:00Z")
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(DailyNoteTarget(date: instant, timeZone: la).filename == "2026-10-23.md")
        #expect(DailyNoteTarget(date: instant, timeZone: utc).filename == "2026-10-24.md")
        #expect(DailyNotesIndex.parseDateFilename("2026-02-30.md") == nil)

        let markdown = "🌅 - [ ] Wake up \r\n- [x] Done\n- [X] Shouting\n```\n- [ ] Fenced\n```"
        let tasks = FileTask.tasks(in: markdown)
        #expect(tasks.map(\.title) == ["Wake up", "Done", "Fenced"])
        #expect(tasks.map(\.isChecked) == [false, true, false])
        #expect(tasks[0].markerRange == NSRange(location: 5, length: 3))
        #expect((markdown as NSString).substring(with: tasks[0].lineRange) == "🌅 - [ ] Wake up ")
        #expect((markdown as NSString).substring(with: tasks[1].markerRange) == "[x]")
        #expect(TaskProgress(markdown: markdown) == TaskProgress(completed: 1, total: 3))

        let day = DailyNoteTarget(date: instant, timeZone: utc)
        let cache = { (truncated: Bool) in
            var object = try #require(try JSONSerialization.jsonObject(with: dailyData()) as? [String: Any])
            object["files"] = [day.filename: [
                "filename": day.filename, "language": "Markdown", "content": "- [ ] Partial", "truncated": truncated]]
            return CachedLibrarySnapshot(
                accountID: UUID(), owned: [try decodeGist(JSONSerialization.data(withJSONObject: object))],
                starred: [], preferences: Preferences(metadata: [:]))
        }
        #expect(DailyNote(day: day, cache: try cache(true), drafts: []).progress == nil)
        let today = DailyNote(day: day, cache: try cache(false), drafts: [])
        #expect(today.gistID == "abc123")
        #expect(today.progress?.remaining == 1)
        #expect(today.date == DailyNotesIndex.parseDateFilename(day.filename, timeZone: utc))
        #expect(DailyNote(day: day, cache: nil, drafts: []).progress == nil)
        #expect(GistConventions.dailyContent(template: nil, dateFilename: "2026-10-24.md")
            == "# 2026-10-24\n\n")
        #expect(GistConventions.dailyContent(
            template: GistConventions.emptyContent, dateFilename: "2026-10-24.md"
        ) == "")
    }
}
