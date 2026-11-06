import Foundation
import Store
import Testing

@testable import Model

@MainActor
struct OpeningTests {
  @Test func `I launch to my gists and land on the note I left, even offline`() async throws {
    let phone = try await Phone {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One", "Ideas.md": "Ideas"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    #expect(Set(phone.rows.map(\.id)) == ["a", "b"])
    #expect(phone.onScreen == nil)
    try await phone.open(.gist(id: "a", filename: "Ideas.md"))
    try await phone.leftover("b", text: "Two, edited")

    phone.goOffline()
    await phone.relaunch()
    #expect(Set(phone.rows.map(\.id)) == ["a", "b"])
    #expect(phone.onScreen == "Ideas")
    #expect(phone.publishes.isEmpty)

    // Back online, the launch publishes what was left behind and keeps the note on screen.
    phone.goOnline()
    await phone.relaunch()
    #expect(phone.publishes == ["PATCH /gists/b"])
    #expect(phone.onGitHub("b") == "Two, edited")
    await phone.model.refresh()
    #expect(phone.onScreen == "Ideas")
  }

  @Test func `A note I've opened shows at once, and my latest tap wins`() async throws {
    let phone = try await Phone {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
      $0.addGist(id: "c", description: "Third", files: ["README.md": "Three"])
    }
    // A link can open a gist before GitHub's list arrives, and it stays selected once its row does.
    let list = phone.fixture.hold("GET /gists/starred")
    let launching = Task { await phone.launch() }
    try await list.arrival()
    try await phone.open(.gist(id: "a"))
    list.open()
    await launching.value
    #expect(phone.model.state.selectedID == "a")

    phone.goOffline()
    await phone.model.open(.gist(id: "b"))
    #expect(phone.model.opening?.failure != nil, "A note this iPhone never had can't open offline.")
    phone.goOnline()

    let slow = phone.fixture.hold("GET /gists/b")
    let older = Task { await phone.model.open(.gist(id: "b")) }
    try await slow.arrival()
    try await phone.open(.gist(id: "c"))
    slow.open()
    await older.value
    #expect(phone.model.state.selectedID == "c")
    #expect(phone.onScreen == "Three")
    #expect(phone.model.opening == nil)

    // A note this iPhone already has opens at once, without asking GitHub.
    try await phone.open(.gist(id: "b"))
    let requests = phone.github.requests
    phone.model.select(rowID: "c")
    #expect(phone.model.opening == nil)
    #expect(phone.onScreen == "Three")
    await Task.yield()
    #expect(phone.github.requests == requests)
  }
}
