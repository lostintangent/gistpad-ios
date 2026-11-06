import Foundation
import Sync
import Testing

@testable import Notebook

@MainActor
struct ConflictsTests {
  @Test func `When the web changed a note too, I choose which version stays`() async throws {
    let phone = try await Phone(autosave: false) {
      $0.addGist(id: "a", description: "First", files: ["README.md": "One", "Other.md": "Two"])
    }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a", filename: "README.md"))
    try await phone.type("Mine", in: a)
    phone.webEdits("a", ["README.md": "Theirs"])
    await a.publish()
    let review = try a.reviewContext()
    #expect(review.conflict.local == "Mine")
    #expect(review.conflict.remote == "Theirs")
    #expect(phone.onGitHub("a") == "Theirs")
    try await a.applyReview(review, text: "Mine", publishes: true)
    #expect(phone.onGitHub("a") == "Mine")
    #expect(a.saveState == .savedToGitHub)

    // Taking GitHub's version doesn't publish anything.
    try await phone.type("Mine again", in: a)
    phone.webEdits("a", ["README.md": "Theirs again"])
    await a.publish()
    try await a.applyReview(a.reviewContext(), text: "Theirs again", publishes: false)
    #expect(phone.onScreen == "Theirs again")
    #expect(a.saveState == .savedToGitHub)
    #expect(phone.publishes == ["PATCH /gists/a"])

    // Keeping mine brings back a file deleted on the web.
    try await phone.type("Mine", in: a)
    phone.webEdits("a", ["README.md": nil])
    await a.publish()
    let deleted = try a.reviewContext()
    #expect(deleted.conflict.remote == nil)
    try await a.applyReview(deleted, text: "Mine", publishes: true)
    #expect(phone.onGitHub("a") == "Mine")
  }

  @Test func `What I wrote in a gist deleted on the web stays here until I delete it`() async throws {
    let phone = try await Phone { $0.addGist(id: "a", description: "First", files: ["README.md": "One"]) }
    await phone.launch()
    let a = try await phone.open(.gist(id: "a"))
    phone.goOffline()
    try await phone.type("Mine", in: a)
    await phone.leave(a)
    phone.goOnline()
    try await phone.webDeletes("a")
    await phone.library.refresh()
    let row = try #require(phone.rows.first)
    #expect(phone.rows.count == 1)
    #expect(row.isRecovery)
    let kept = try await phone.open(.draft(id: try #require(UUID(uuidString: row.id))))
    #expect(phone.onScreen == "Mine")
    await kept.publish()
    await phone.leave(kept)
    await phone.leaveApp()
    await phone.returnToApp()
    #expect(phone.publishes.isEmpty)
    #expect(phone.github.gists.isEmpty)
    try await phone.delete(row: row.id)
    #expect(phone.rows.isEmpty)
  }
}
