import Foundation
import Store
import Testing

@testable import Model

@MainActor
struct RefreshingTests {
  @Test func `The web's changes show up as I come back, without replacing what I'm reading`() async throws {
    let phone = try await Phone(preferences: LibraryTests.ideas) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    phone.model.state.query = "First"
    phone.model.state.selectedTagIDs = ["ideas"]

    // A refresh updates the list and leaves the open note and my filters alone.
    phone.github.edit("a", description: "Renamed on the web", files: ["README.md": "One, from the web"])
    try await phone.webDeletes("b")
    await phone.model.refresh()
    #expect(phone.rows.map(\.title) == ["Renamed on the web"])
    #expect(phone.onScreen == "One")
    #expect(phone.model.state.query == "First")
    #expect(phone.model.state.selectedTagIDs == ["ideas"])
    #expect(phone.model.state.selectedID == "a")

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
    await phone.model.refresh()
    #expect(phone.status == "Couldn't update your gists")
    phone.dropRequests(.networkConnectionLost)
    await phone.model.refresh()
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
    let read = phone.fixture.hold("GET /gists/a")
    let relaunching = Task { await phone.relaunch() }
    try await read.arrival()
    #expect(phone.onScreen == "One, from the web")
    read.open()
    await relaunching.value
    #expect(phone.onScreen == "Changed again")
    #expect(phone.publishes.isEmpty)
  }
}
