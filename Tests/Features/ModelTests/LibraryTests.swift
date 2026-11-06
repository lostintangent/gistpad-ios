import Foundation
import Store
import Testing

@testable import Model

@MainActor
struct LibraryTests {
  /// A pinned gist "a" tagged Ideas, like the web saves them.
  static let ideas: [GistPadPreferences.Change] = [
    .setPinned(gistID: "a", pinned: true),
    .upsertTag(id: "ideas", name: "Ideas", color: "#EBC85A"),
    .setTag(gistID: "a", tagID: "ideas", included: true),
  ]

  @Test func `My list shows my gists and the ones I starred, as the web marks them`() async throws {
    let phone = try await Phone(preferences: Self.ideas) {
      $0.addGist(
        id: "a", description: "Mine", files: ["README.md": "A"], isStarred: true,
        comments: ["One", "Two"])
      $0.addGist(id: "c", description: "Diagram", files: ["README.md": "C", "diagram.png": "PNG"])
      $0.addGist(
        id: "b", description: "Theirs", files: ["b.md": "B"], owner: FixtureServer.someoneElse,
        isStarred: true)
      // The account still carries the login from before a GitHub rename.
      $0.mergeMetadata(["user_name": "octocat-before-rename"])
    }
    await phone.launch()
    #expect(phone.rows.count == 3)
    let mine = try #require(phone.row("a"))
    #expect(mine.isOwned)
    #expect(mine.isStarred)
    #expect(mine.isPinned)
    #expect(mine.isSecret)
    #expect(mine.tagIDs == ["ideas"])
    #expect(mine.commentCount == 2)
    #expect(phone.model.state.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
    #expect(phone.row("b")?.isOwned == false)
    #expect(try await phone.open(.gist(id: "a")).details.access == .editable)

    phone.model.recordCommentCount(accountID: phone.accountID, gistID: "a", total: 3)
    #expect(phone.row("a")?.commentCount == 3)
    #expect(phone.row("c")?.visibleFileCount == nil, "A row counts its Markdown files from two.")
    try await phone.add("Ideas.md", to: "c")
    #expect(phone.row("c")?.visibleFileCount == 2)
  }
}
