import Foundation
import Sync
import Testing

@testable import Notebook

@MainActor
struct DailyNotesTests {
  @Test func `Today opens one note from my template, however many times I tap it`() async throws {
    let phone = try await Phone(lastFile: .init(gistID: "a", filename: "README.md", draftID: nil)) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: ["template.md": "# {{date}}\n\n- [ ] Plan {{date}}\n"])
    }
    await phone.launch()
    #expect(phone.onScreen == "Text")
    let first = Task { await phone.library.open(.today()) }
    let second = Task { await phone.library.open(.today()) }
    await first.value
    await second.value
    let today = try #require(phone.library.activeSession)
    let date = DailyNote.Day().filename.dropLast(3)
    #expect(today.draft.filename == DailyNote.Day().filename)
    #expect(phone.onScreen == "# \(date)\n\n- [ ] Plan \(date)\n")
    #expect(phone.publishes.isEmpty)

    // A Today tap focuses the editor once, and again only for a fresh tap.
    today.requestCreationFocus()
    #expect(today.mode == .edit)
    today.mode = .preview
    today.requestCreationFocus()
    #expect(today.mode == .preview)
    await phone.library.open(.today())
    today.adoptPresentation(try #require(phone.library.loadedFile))
    today.requestCreationFocus()
    #expect(today.mode == .edit)

    try await phone.type("- [ ] One task", in: today)
    await today.publish()
    try await phone.open(.gist(id: "a"))
    try await phone.open(.today())
    #expect(phone.onScreen == "- [ ] One task")
    #expect(phone.publishes == ["PATCH /gists/d"])
    #expect(Set(try #require(phone.github.gists.first { $0.id == "d" }).files.keys)
      == ["template.md", today.draft.filename])

    // A Today action for another day opens that day.
    let target = DailyNote.Day(
      date: Date(timeIntervalSince1970: 1_790_208_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    try await phone.open(.today(target))
    #expect(phone.library.loadedFile?.draft.filename == target.filename)
    #expect(phone.library.loadedFile?.editingRequestID != nil)
  }

  @Test func `Each day shows its tasks, read from GitHub only when the day changed`() async throws {
    let today = DailyNote.filename()
    let phone = try await Phone {
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: [today: "- [x] One\n- [ ] Two", "2026-01-02.md": "- [ ] Carried over"],
        updatedAt: .now - 60)
    }
    let raw = "GET /\(FixtureServer.you.login)/d/raw/\(today)"
    let reads = { phone.github.requests.filter { $0 == raw }.count }
    phone.fixture.fail(raw)
    await phone.launch()
    #expect(phone.status == nil)
    #expect(phone.library.state.today.text == nil)

    phone.goOnline()
    await phone.library.refresh()
    #expect(phone.onScreen == nil)
    #expect(phone.library.state.today.progress == .init(completed: 1, total: 2))
    await phone.library.refresh()
    #expect(reads() == 1)
    phone.webEdits("d", [today: "- [x] One\n- [x] Two"])
    await phone.library.refresh()
    #expect(reads() == 2)
    #expect(phone.library.state.today.progress == .init(completed: 2, total: 2))
    #expect(phone.row("d/\(today)")?.progress == .init(completed: 2, total: 2))

    // GitHub lists gists without their text, so an earlier day's tasks show once it's opened.
    let past = "d/2026-01-02.md"
    try await phone.open(row: past)
    #expect(phone.library.gistID(forRow: past) == "d")
    #expect(phone.library.gistID(forRow: "d/2026-01-03.md") == nil)
    let index = try #require(phone.library.state.gists.firstIndex { $0.id == past })
    #expect(phone.library.state.gists[index].isOverdue)
    // A row drawn before midnight is stale until the calendar changes.
    phone.library.state.gists[index].isOverdue = false
    phone.library.updateCalendar()
    #expect(phone.library.state.gists[index].isOverdue)
  }

  @Test func `A day I wrote here keeps one row from typing to publishing`() async throws {
    let today = DailyNote.filename()
    let phone = try await Phone(autosave: false) {
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: [today: "- [x] One\n- [ ] Two\nA third line stays out of the excerpt.", "2026-10-23.md": "An earlier day"])
    }
    let leftover = try await phone.leftover("d", "2026-10-24.md", text: "- [ ] A retained task")
    await phone.launch()
    #expect(phone.publishes == ["PATCH /gists/d"])
    let todayRow = try #require(phone.row("d/\(today)"))
    #expect(todayRow.dailyDate == DailyNote.date(filename: today))
    #expect(todayRow.progress == .init(completed: 1, total: 2))
    #expect(phone.library.state.dailyNoteCount == 3)

    let id = "d/2026-10-24.md"
    let day = try await phone.open(row: id)
    let text = "- [x] A retained task\n- [ ] A new task"
    try await phone.type(text, in: day)
    let row = try #require(phone.row(id))
    #expect(row.progress == .init(completed: 1, total: 2))
    #expect(row.isOverdue)
    await day.publish()
    #expect(phone.onGitHub("d", "2026-10-24.md") == text)
    #expect(phone.library.state.selectedID == id)
    #expect(phone.library.state.dailyNoteCount == 3)
    #expect(phone.library.state.gists.filter { $0.id == id }.count == 1)
    #expect(phone.row(leftover.id.uuidString) == nil)
  }

  @Test func `A day I delete while it publishes removes only that day`() async throws {
    let phone = try await Phone(lastFile: .init(gistID: "a", filename: "README.md", draftID: nil)) {
      $0.addGist(id: "a", description: "Somewhere else", files: ["README.md": "Text"])
    }
    // An earlier day written offline, before there was a daily notes gist.
    let earlier = try await phone.fixture.store.save(
      Draft(
        accountID: phone.accountID, githubUserID: FixtureServer.you.id, filename: "2026-10-23.md",
        description: DailyNote.gistDescription),
      text: "The alpha day", generation: 1)
    await phone.library.start()
    // I confirm its deletion as the launch publishes it, and Today joins the gist it creates.
    let deletion = try phone.deletion(row: earlier.id.uuidString)
    await phone.library.publishDrafts()
    let gistID = try #require(phone.github.gists.first(where: \.isDailyNote)?.id)
    let today = try await phone.open(.today())
    #expect(today.draft.gistID == gistID)
    try await phone.type("- [ ] Today's task", in: today)
    await today.publish()
    #expect(phone.onGitHub(gistID, "2026-10-23.md") == "The alpha day")

    try await phone.delete(deletion)
    #expect(phone.onGitHub(gistID, "2026-10-23.md") == nil)
    #expect(phone.onGitHub(gistID, today.draft.filename) == "- [ ] Today's task")
  }
}
