import Foundation
import Sync
import Testing

@testable import Notebook

@MainActor
struct AccountsTests {
  @Test func `What I typed survives signing out, and waits while another account signs in`() async throws {
    let phone = try await Phone {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One"])
      $0.addGist(
        id: "shared", description: "Theirs", files: ["README.md": "Hi"],
        owner: FixtureServer.someoneElse, isStarred: true)
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    let mine = "Mine e\u{301} 日本語 👩🏽‍💻"
    phone.goOffline()
    try await phone.type(mine, in: a)
    await phone.leave(a)
    phone.goOnline()
    // Someone else's gist I'm reading doesn't hold up signing out.
    _ = try await phone.open(.gist(id: "shared"))
    try await phone.signOut()
    #expect(phone.library.account == nil)
    #expect(phone.library.state.loadState == .signedOut)
    #expect(phone.library.state.gists.isEmpty)
    #expect(phone.onScreen == nil)
    await phone.library.signIn()
    #expect(phone.library.account?.id == phone.accountID)
    await phone.returnToApp()
    #expect(phone.onGitHub("a")?.utf8.elementsEqual(mine.utf8) == true)

    // When someone else signs in and I keep my account, my edits wait until I reconnect.
    let again = try await phone.open(.gist(id: "a"))
    try await phone.type("Mine again", in: again)
    let other = UUID()
    try phone.fixture.signInNext(as: other, login: FixtureServer.someoneElse.login)
    await phone.library.signIn()
    #expect(phone.library.account?.id == phone.accountID)
    #expect(phone.library.pendingAccount?.id == other)
    phone.library.keepCurrentAccount()
    #expect(phone.library.pendingAccount == nil)
    await phone.leave(again)
    #expect(phone.onGitHub("a")?.utf8.elementsEqual(mine.utf8) == true)
    guard case .reconnectRequired = phone.library.state.loadState else {
      Issue.record("Expected a prompt to reconnect")
      return
    }
  }
}
