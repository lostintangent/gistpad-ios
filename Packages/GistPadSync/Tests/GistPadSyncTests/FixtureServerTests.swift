import Foundation
import Testing
@testable import GistPadSync

struct FixtureServerTests {
    @Test func signInGistsStarsAndMetadataRoundTrip() async throws {
        let server = FixtureServer()
        server.addGist(
            id: "theirs", description: "Starred", files: ["a.md": "hi"],
            owner: FixtureServer.someoneElse, isStarred: true, comments: ["Nice"])
        let accounts = try server.accounts()
        let account = try await server.signIn(accounts)
        #expect(account.login == FixtureServer.you.login)
        let github = await accounts.githubClient(accountID: account.id)

        let created = try await github.createGist(description: "Ideas", content: "# Ideas")
        #expect(try await github.listGists().map(\.id) == [created.id])
        #expect(try await github.listStarredGists().map(\.id) == ["theirs"])
        #expect(try await github.listComments(gistID: "theirs").map(\.body) == ["Nice"])

        let edited = try await github.updateGist(
            id: created.id, files: ["README.md": .rename("Ideas.md"), "Today.md": .content("- [ ] Ship")])
        #expect(edited.files.keys.sorted() == ["Ideas.md", "Today.md"])
        #expect(try await github.content(gist: edited, filename: "Ideas.md") == "# Ideas")
        try await github.setStarred(true, id: created.id)
        #expect(Set(try await github.listStarredGists().map(\.id)) == [created.id, "theirs"])

        let pinned = try await accounts.apply([.setPinned(gistID: created.id, pinned: true)], accountID: account.id)
        #expect(pinned.preferences.pinnedGists == [created.id])
        try await github.deleteGist(id: created.id)
        #expect(server.gists.map(\.id) == ["theirs"])
        await #expect(throws: GitHubClientError.self) { try await github.gist(id: created.id) }
        #expect(server.requests.contains("PATCH /gists/\(created.id)"))
    }
}
