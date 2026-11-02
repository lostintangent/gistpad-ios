import Foundation
import Synchronization
import Testing
@testable import GistPadSync

/// The typed GitHub client: fresh reads, the token's reach, and the web's conventions on the wire.
@Suite struct GitHubClientTests {
    @Test func libraryListsAreFreshAndCoverOwnedAndStarred() async throws {
        let count = Mutex(0)
        let session = FakeURLProtocol.session { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            count.withLock { $0 += 1 }
            if request.url?.query?.contains("page=2") == true {
                return FakeResponse(data: Data("[]".utf8))
            }
            let markdown = try gistData()
            let image = try gistData(id: "def456", filename: "photo.png", language: "")
            let list = Data("[".utf8) + markdown + Data(",".utf8) + image + Data("]".utf8)
            return FakeResponse(
                headers: ["Link": "<https://api.github.com/gists?page=2>; rel=\"next\"", "Cache-Control": "max-age=60"],
                data: list)
        }
        let client = GitHubClient(session: session) { "fake" }
        #expect(try await client.listGists().count == 2)
        #expect(try await client.listStarredGists().count == 1)
        #expect(try await client.listGists().count == 2)
        #expect(count.withLock { $0 } == 6)
    }

    @Test func theTokenOnlyGoesToGitHub() async throws {
        let hosts = Mutex<[String]>([])
        let session = FakeURLProtocol.session { request in
            hosts.withLock { $0.append(request.url?.host ?? "") }
            if request.url?.host == "gist.githubusercontent.com" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return FakeResponse(data: Data("raw".utf8))
            }
            return FakeResponse(
                headers: ["Link": "<https://example.com/gists?page=2>; rel=\"next\""], data: Data("[]".utf8))
        }
        let client = GitHubClient(session: session) { "fake" }
        await #expect(throws: GitHubClientError.unsafeURL) { try await client.listGists() }
        #expect(try await client.content(gist: rawGist(), filename: "README.md") == "raw")
        await #expect(throws: GitHubClientError.unsafeURL) {
            try await client.content(gist: rawGist(url: "https://example.com/raw/README.md"), filename: "README.md")
        }
        #expect(hosts.withLock { $0 } == ["api.github.com", "gist.githubusercontent.com"])
    }

    @Test func emptySavesUseSentinelAndCreatesAreSecret() async throws {
        let server = FixtureServer()
        let client = GitHubClient(session: server.session) { "fixture-github" }
        let created = try await client.createGist()
        #expect(created.isPublic == false)
        #expect(server.gists[0].files["README.md"]?.content == GistFile.emptyContent)
        let saved = try await client.updateGist(id: created.id, files: ["README.md": .content("")])
        #expect(server.gists[0].files["README.md"]?.content == GistFile.emptyContent)
        #expect(try await client.content(gist: saved, filename: "README.md") == "")
    }

    @Test func throttlingDoesNotLookLikeSignOut() async throws {
        let session = FakeURLProtocol.session { _ in
            FakeResponse(status: 403, headers: ["Retry-After": "60"])
        }
        let client = GitHubClient(session: session) { "fake" }
        do {
            _ = try await client.gist(id: "abc123")
            Issue.record("Expected throttling")
        } catch GitHubClientError.http(let status, let retry) {
            #expect(status == 403)
            #expect(try #require(retry).timeIntervalSinceNow > 50)
        }
    }

    @Test func largeFilesOpenInFullAndAnIncompleteGistIsNeverPublished() async throws {
        let requests = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            requests.withLock { $0 += 1 }
            return FakeResponse(data: Data("complete content".utf8))
        }) { "fake" }
        #expect(try await client.content(gist: rawGist(content: "partial"), filename: "README.md") == "complete content")
        await #expect(throws: GitHubClientError.incompleteGist) {
            try await client.content(gist: decodeGist(gistData(truncated: true)), filename: "README.md")
        }
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func gistVerbsMatchGitHubAndTheWebsConventions() async throws {
        let server = FixtureServer()
        let gist = server.addGist(description: "Note", files: ["README.md": "hello", "old.md": "bye"])
        let client = GitHubClient(session: server.session) { "fixture-github" }

        let renamed = try await client.updateGist(
            id: gist.id, files: ["README.md": .rename("Renamed.md"), "old.md": .delete])
        #expect(server.gists[0].files.mapValues(\.content) == ["Renamed.md": "hello"])
        let archived = try await client.setArchived(true, gist: renamed)
        #expect(archived.description == "Note [Archived]")
        #expect(archived.isArchived)
        #expect(archived.displayDescription == "Note")
        let described = try await client.updateDescription("Better", gist: archived)
        #expect(described.description == "Better [Archived]")
        #expect(try await client.setArchived(false, gist: described).description == "Better")
        #expect(try decodeGist(gistData(description: "Note   [Archived]")).displayDescription == "Note")

        try await client.setStarred(true, id: gist.id)
        #expect(try await client.listStarredGists().map(\.id) == [gist.id])
        try await client.setStarred(false, id: gist.id)
        #expect(try await client.listStarredGists().isEmpty)
        try await client.deleteGist(id: gist.id)
        #expect(server.gists.isEmpty)
        #expect(server.requests.filter { !$0.hasPrefix("GET") } == [
            "PATCH /gists/\(gist.id)", "PATCH /gists/\(gist.id)", "PATCH /gists/\(gist.id)",
            "PATCH /gists/\(gist.id)", "PUT /gists/\(gist.id)/star", "DELETE /gists/\(gist.id)/star",
            "DELETE /gists/\(gist.id)",
        ])
    }
}

/// A gist whose README lives only behind its raw URL, the way GitHub serves large files.
private func rawGist(
    content: String? = nil, url: String = "https://gist.githubusercontent.com/test/abc123/raw/README.md"
) throws -> Gist {
    var object = try #require(try JSONSerialization.jsonObject(with: gistData()) as? [String: Any])
    var file: [String: Any] = ["filename": "README.md", "language": "Markdown", "truncated": true, "raw_url": url]
    file["content"] = content
    object["files"] = ["README.md": file]
    return try decodeGist(JSONSerialization.data(withJSONObject: object))
}
