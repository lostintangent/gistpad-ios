import Foundation
import Sync
import Testing

@testable import Notebook

@MainActor
struct ChangesTests {
  @Test func `Deleting a gist removes it from GitHub, or only from here if it never got there`() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("One, typed", in: a)
    try await phone.delete(row: "a")
    #expect(phone.github.requests.filter { $0.hasPrefix("DELETE") } == ["DELETE /gists/a"])
    #expect(phone.github.gists.map(\.id) == ["b"])
    #expect(phone.rows.map(\.id) == ["b"])
    #expect(phone.onScreen == nil)

    phone.goOffline()
    let new = try await phone.open(.new)
    try await phone.type("# Draft\n\nNever published", in: new)
    try await phone.delete(row: try #require(phone.rows.first { $0.id != "b" }).id)
    #expect(phone.onScreen == nil)
    #expect(phone.rows.map(\.id) == ["b"])
    await phone.relaunch()
    #expect(phone.rows.map(\.id) == ["b"])
    #expect(phone.onScreen == nil)
    phone.goOnline()
    await phone.returnToApp()
    #expect(phone.publishes.isEmpty)
  }

  @Test func `Deleting a day removes just that day, and the gist with its last day`() async throws {
    let today = DailyNote.Day().filename
    let phone = try await Phone {
      $0.addGist(
        id: "d", description: DailyNote.gistDescription,
        files: [today: "Today's words", "2026-10-23.md": "The alpha day", "2026-10-24.md": "The beta day"])
    }
    await phone.launch()
    try await phone.open(row: "d/2026-10-24.md")
    #expect(phone.onScreen == "The beta day")
    try await phone.open(row: "d/2026-10-23.md")
    #expect(phone.onScreen == "The alpha day")
    try await phone.open(.gist(id: "d", filename: "2026-10-24.md"))
    #expect(phone.library.state.selectedID == "d/2026-10-24.md")
    #expect(try phone.deletion(row: "d/2026-10-24.md") == .file(gistID: "d", filename: "2026-10-24.md"))
    try await phone.delete(row: "d/2026-10-24.md")
    #expect(phone.onScreen == nil)
    #expect(phone.onGitHub("d", "2026-10-24.md") == nil)
    #expect(phone.onGitHub("d", "2026-10-23.md") == "The alpha day")

    // Today closes when I delete it, and stays gone until I open it again.
    try await phone.open(.today())
    try await phone.delete(row: "d/\(today)")
    #expect(phone.onScreen == nil)
    #expect(phone.onGitHub("d", today) == nil)
    await phone.returnToApp()
    #expect(phone.days == ["d/2026-10-23.md"])
    let fresh = try await phone.open(.today())
    #expect(phone.onScreen == "# \(today.dropLast(3))\n\n")
    await phone.leave(fresh)

    try await phone.delete(row: "d/2026-10-23.md")
    #expect(phone.github.gists.isEmpty)
    #expect(phone.days.isEmpty)
  }

  @Test func `Renaming, starring and pinning wait for a connection, and someone else's gist is read only`() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(
        id: "shared", description: "Theirs", files: ["README.md": "Theirs"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    await phone.launch()
    phone.goOffline()
    await #expect(throws: (any Error).self) { try await phone.rename("a", to: "Renamed") }
    await #expect(throws: (any Error).self) { try await phone.star("a") }
    await #expect(throws: (any Error).self) { try await phone.pin("a") }
    phone.goOnline()
    await phone.returnToApp()
    #expect(phone.github.gists.first { $0.id == "a" }?.description == "First")
    #expect(phone.row("a")?.isStarred == false)
    #expect(phone.row("a")?.isPinned == false)

    try await phone.rename("a", to: "Renamed")
    try await phone.star("a")
    try await phone.pin("a")
    #expect(phone.github.gists.first { $0.id == "a" }?.description == "Renamed")
    let a = try #require(phone.row("a"))
    #expect(a.title == "Renamed")
    #expect(a.isStarred)
    #expect(a.isPinned)

    // Renaming a file keeps what I typed in it.
    let session = try await phone.open(.gist(id: "a"))
    try await phone.type("Mine", in: session)
    try await phone.rename("a", "README.md", to: "Notes.md")
    #expect(session.editor.text == "Mine")
    await phone.leave(session)
    #expect(phone.onGitHub("a", "Notes.md") == "Mine")
    #expect(phone.onGitHub("a", "README.md") == nil)

    let shared = try await phone.open(.gist(id: "shared"))
    #expect(!shared.details.access.canEdit)
    #expect(!shared.editor.isEditable)
    #expect(phone.library.deletion(forRow: "shared") == nil)
  }
}
