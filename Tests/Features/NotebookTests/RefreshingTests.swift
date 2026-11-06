import Foundation
import Sync
import Testing

@testable import Notebook

@MainActor
struct RefreshingTests {
  @Test func `The web's changes show up as I come back, without replacing what I'm reading`() async throws {
    let phone = try await Phone(preferences: LibraryTests.ideas) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    phone.library.state.query = "First"
    phone.library.state.selectedTagIDs = ["ideas"]

    // A refresh updates the list and leaves the open note and my filters alone.
    phone.github.edit("a", description: "Renamed on the web", files: ["README.md": "One, from the web"])
    try await phone.webDeletes("b")
    await phone.library.refresh()
    #expect(phone.rows.map(\.title) == ["Renamed on the web"])
    #expect(phone.onScreen == "One")
    #expect(phone.library.state.query == "First")
    #expect(phone.library.state.selectedTagIDs == ["ideas"])
    #expect(phone.library.state.selectedID == "a")

    // Coming back reads the open note, which then waits five minutes before reading it again.
    await phone.returnToApp()
    #expect(phone.onScreen == "One, from the web")
    phone.webEdits("a", ["README.md": "Changed again"])
    phone.github.addGist(id: "c", description: "Third", files: ["README.md": "Three"])
    try await phone.open(.gist(id: "c"))
    #expect(try await phone.open(.gist(id: "a")) === a)
    await a.inspectRemoteChanges()
    #expect(phone.onScreen == "One, from the web")

    // A refresh that fails keeps what I have. A dropped connection stays quiet.
    phone.dropRequests(.notConnectedToInternet)
    await phone.library.refresh()
    #expect(phone.status == "Couldn't update your gists")
    phone.dropRequests(.networkConnectionLost)
    await phone.library.refresh()
    #expect(phone.status == nil)
    #expect(phone.rows.map(\.id) == ["a"])

    // Coming back tries again.
    phone.goOnline()
    let list = phone.fixture.hold("GET /gists/starred")
    let returning = Task { await phone.returnToApp() }
    try await list.arrival()
    #expect(phone.status == "Checking")
    list.open()
    await returning.value
    #expect(Set(phone.rows.map(\.id)) == ["a", "c"])
    #expect(phone.status == nil)

    // A relaunch shows this iPhone's copy first, then GitHub's newer text.
    await phone.relaunch()
    #expect(phone.onScreen == "One, from the web")
    await phone.library.activeSession?.inspectRemoteChanges()
    #expect(phone.onScreen == "Changed again")
    #expect(phone.publishes.isEmpty)
  }
}
