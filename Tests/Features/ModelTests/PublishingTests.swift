import Foundation
import Store
import Testing

@testable import Model

@MainActor
struct PublishingTests {
  @Test func `What I type is saved here at once and publishes once I stop`() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    // Opening a note or Today and leaving it untouched publishes nothing and makes no day.
    await phone.leave(try await phone.open(.today()))
    await phone.leave(try await phone.open(.gist(id: "a")))
    await phone.returnToApp()
    #expect(phone.publishes.isEmpty)
    #expect(phone.days.isEmpty)

    let a = try await phone.open(.gist(id: "a"))
    let typed = "One, 日本語 👨‍👩‍👧‍👦"
    try await phone.type("One,", "One, 日本", typed, in: a)
    #expect(a.status == .unpublished)
    #expect(phone.publishes.isEmpty)

    // Typing while a publish is on its way publishes next, once typing stops.
    let sending = phone.fixture.hold("PATCH /gists/a")
    let publishing = Task { await a.publish() }
    try await sending.arrival()
    try await phone.type("Second", in: a)
    sending.open()
    await publishing.value
    #expect(phone.onGitHub("a")?.utf8.elementsEqual(typed.utf8) == true)
    #expect(a.status == .unpublished)
    await a.updateAutosave()?.value
    #expect(phone.publishes == ["PATCH /gists/a", "PATCH /gists/a"])
    #expect(phone.onGitHub("a") == "Second")

    let kept = "Third e\u{301} 👩🏽‍💻"
    try await phone.type(kept, in: a)
    phone.goOffline()
    await phone.relaunch()
    #expect(phone.onScreen?.utf8.elementsEqual(kept.utf8) == true)
  }

  @Test func `With autosave off, a note publishes when I leave it or the app`() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(id: "b", description: "Second", files: ["README.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("One, typed", in: a)
    #expect(a.updateAutosave() == nil)
    let b = try await phone.open(.gist(id: "b"))
    #expect(phone.onGitHub("a") == "One, typed")
    try await phone.type("Two, typed", in: b)
    await phone.leaveApp()
    #expect(phone.onGitHub("b") == "Two, typed")
    #expect(b.status == .published)
  }

  enum Moment: CaseIterable { case autosave, leavingTheNote, leavingTheApp, returningToTheApp }

  @Test(arguments: Moment.allCases)
  func `What I wrote offline publishes at the next chance`(_ moment: Moment) async throws {
    let phone = try await Phone()
    await phone.launch()
    phone.goOffline()
    let today = try await phone.open(.today())
    try await phone.type("# Today\n\n- [ ] Walk", in: today)
    await today.publish()
    #expect(today.status == .failed(.offline))
    phone.goOnline()
    switch moment {
    case .autosave:
      try await phone.type("# Today\n\n- [ ] Walk the dog", in: today)
      await today.updateAutosave()?.value
    case .leavingTheNote: await phone.leave(today)
    case .leavingTheApp: await phone.leaveApp()
    case .returningToTheApp: await phone.returnToApp()
    }
    #expect(phone.publishes == ["POST /gists"])
    #expect(today.status == .published)
    let daily = try #require(phone.github.gists.first { $0.isDailyNote })
    #expect(daily.files[DailyNote.Day().filename]?.content == today.editor.text)
    #expect(daily.isPublic == false)
  }

  @Test func `When GitHub's answer to a publish is lost, what I type next still publishes`()
    async throws
  {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "Note", files: ["README.md": "base"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    try await phone.type("local", in: a)
    phone.fixture.cutOffNextPublish()
    await a.publish()
    #expect(phone.onGitHub("a") == "local")

    try await phone.type("base", in: a)
    await a.publish()
    #expect(a.status == .published)
    #expect(phone.onGitHub("a") == "base")
  }

  @Test(arguments: [false, true])
  func `When GitHub's answer to a new gist is lost, it's still made only once`(daily: Bool)
    async throws
  {
    // Same title and file with other text, so only the text tells them apart.
    let phone = try await Phone(autosave: false) {
      $0.addGist(description: "Ideas", files: ["README.md": "# Ideas\n\nOlder"])
    }
    await phone.launch()
    let new = try await phone.open(daily ? .today() : .new)
    if !daily { try await phone.name(new, "Ideas") }
    try await phone.type("# Ideas\n\nFirst", in: new)
    phone.fixture.cutOffNextPublish()
    await new.publish()
    #expect(new.status != .published)

    await new.publish()
    #expect(new.status == .published)
    let made = phone.github.gists.filter {
      $0.files[new.file.filename]?.content == "# Ideas\n\nFirst"
    }
    #expect(made.map(\.id) == [new.file.current.gistID])
    #expect(phone.publishes == ["POST /gists"])
  }

  @Test func `A gist I start and name offline is created when I'm back`() async throws {
    let phone = try await Phone()
    await phone.launch()
    phone.goOffline()
    let new = try await phone.open(.new)
    #expect(phone.onScreen == "")
    try await phone.name(new, "Ideas")
    await phone.leave(new)
    #expect(phone.rows.map(\.title) == ["Ideas"])
    #expect(phone.publishes.isEmpty)
    phone.goOnline()
    await phone.returnToApp()
    let gist = try #require(phone.github.gists.first)
    #expect(gist.description == "Ideas")
    #expect(phone.publishes == ["POST /gists"])
    #expect(phone.rows.map(\.id) == [gist.id])
  }
}
