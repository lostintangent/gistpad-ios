import Foundation
import Synchronization
import Testing
@testable import GistPadSync

@Suite struct GitHubClientTests {
    @Test func paginatesAndMatchesDifferentLibraryAndStarredFilters() async throws {
        let count = Mutex(0)
        let session = FakeURLProtocol.session { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
            count.withLock { $0 += 1 }
            if request.url?.query?.contains("page=2") == true {
                return FakeResponse(data: Data("[]".utf8))
            }
            let markdown = try gistData()
            let image = try gistData(id: "def456", filename: "photo.png", language: "")
            let list = Data("[".utf8) + markdown + Data(",".utf8) + image + Data("]".utf8)
            return FakeResponse(
                headers: ["Link": "<https://api.github.com/gists?page=2>; rel=\"next\""], data: list
            )
        }
        let client = GitHubClient(session: session) { "fake" }
        #expect(try await client.listGists().count == 2)
        #expect(try await client.listStarredGists().count == 1)
        #expect(count.withLock { $0 } == 4)
    }

    @Test func etagRevalidationUsesCachedBody() async throws {
        let session = FakeURLProtocol.session { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"one\"" {
                return FakeResponse(status: 304)
            }
            return FakeResponse(headers: ["ETag": "\"one\""], data: try gistData())
        }
        let client = GitHubClient(session: session) { "fake" }
        let first = try await client.gist(id: "abc123")
        #expect(try await client.gist(id: "abc123") == first)
    }

    @Test func neverSendsCredentialsToPaginationHost() async throws {
        let calls = Mutex(0)
        let session = FakeURLProtocol.session { _ in
            calls.withLock { $0 += 1 }
            return FakeResponse(
                headers: ["Link": "<https://example.com/gists?page=2>; rel=\"next\""],
                data: Data("[]".utf8)
            )
        }
        let client = GitHubClient(session: session) { "fake" }
        await #expect(throws: GitHubClientError.unsafeURL) { try await client.listGists() }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func emptySavesUseSentinelAndCreatesAreSecret() async throws {
        let session = FakeURLProtocol.session { request in
            let body = try requestBody(request)
            let files = try #require(body["files"] as? [String: [String: String]])
            if request.httpMethod == "POST" {
                #expect(body["public"] as? Bool == false)
                #expect(files["README.md"]?["content"] == GistConventions.emptyContent)
            } else {
                #expect(files["README.md"]?["content"] == GistConventions.emptyContent)
            }
            return FakeResponse(data: try gistData(content: GistConventions.emptyContent))
        }
        let client = GitHubClient(session: session) { "fake" }
        _ = try await client.createGist()
        let saved = try await client.updateGist(id: "abc123", files: ["README.md": .content("")])
        #expect(try await client.content(gist: saved, filename: "README.md") == "")
    }

    @Test func timeoutDoesNotRetryCreate() async throws {
        let count = Mutex(0)
        let session = FakeURLProtocol.session { _ in
            count.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }
        let client = GitHubClient(session: session) { "fake" }
        await #expect(throws: (any Error).self) { try await client.createGist() }
        #expect(count.withLock { $0 } == 1)
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

    @Test func incompleteGistCannotBeEditedFromPartialContent() async throws {
        let gist = try decodeGist(gistData(truncated: true))
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            Issue.record("Incomplete gist must not issue a content request")
            return FakeResponse()
        }) { "fake" }
        await #expect(throws: GitHubClientError.incompleteGist) {
            try await client.content(gist: gist, filename: "README.md")
        }
    }

    @Test func archiveAndDailyConventions() throws {
        let gist = try decodeGist(gistData(description: "Note   [Archived]"))
        #expect(gist.isArchived)
        #expect(gist.displayDescription == "Note")
        let daily = try decodeGist(gistData(description: GistConventions.dailyNotesDescription))
        #expect(daily.isDailyNote)
        #expect(GistConventions.dailyContent(
            template: "# {{date}}\n", dateFilename: "2026-10-24.md"
        ) == "# 2026-10-24\n")
        let date = try Date.ISO8601FormatStyle().parse("2026-10-24T00:00:00Z")
        #expect(GistConventions.todayFilename(date: date, timeZone: TimeZone(secondsFromGMT: 0)!)
            == "2026-10-24.md")
    }

    @Test func typedMutationsMatchGitHubFileAndNoContentShapes() async throws {
        let requests = Mutex<[String]>([])
        let session = FakeURLProtocol.session { request in
            requests.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")") }
            if request.httpMethod == "PATCH" {
                let body = try requestBody(request)
                if let description = body["description"] as? String {
                    #expect(description == "Note [Archived]")
                } else {
                    let files = try #require(body["files"] as? [String: Any])
                    #expect((files["README.md"] as? [String: String])?["filename"] == "Renamed.md")
                    #expect(files["old.md"] is NSNull)
                }
                return FakeResponse(data: try gistData())
            }
            #expect(request.httpBody == nil)
            return FakeResponse(status: 204)
        }
        let client = GitHubClient(session: session) { "fake" }
        _ = try await client.updateGist(
            id: "abc123", files: ["README.md": .rename("Renamed.md"), "old.md": .delete]
        )
        _ = try await client.setArchived(true, gist: decodeGist(gistData()))
        try await client.setStarred(true, id: "abc123")
        try await client.setStarred(false, id: "abc123")
        try await client.deleteGist(id: "abc123")
        #expect(requests.withLock { $0 } == [
            "PATCH /gists/abc123", "PATCH /gists/abc123", "PUT /gists/abc123/star",
            "DELETE /gists/abc123/star", "DELETE /gists/abc123"
        ])
    }

    @Test func truncatedFilesUseRawContentWithoutForwardingTheToken() async throws {
        let gistJSON = try JSONSerialization.jsonObject(with: gistData()) as? [String: Any]
        var object = try #require(gistJSON)
        object["files"] = ["README.md": [
            "filename": "README.md", "language": "Markdown", "content": "partial",
            "truncated": true, "raw_url": "https://gist.githubusercontent.com/test/abc123/raw/README.md"
        ]]
        let gist = try decodeGist(JSONSerialization.data(withJSONObject: object))
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.url?.host == "gist.githubusercontent.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return FakeResponse(data: Data("complete content".utf8))
        }) { "fake" }
        #expect(try await client.content(gist: gist, filename: "README.md") == "complete content")
    }

    @Test func ordinary404DoesNotInheritAnUnrelatedRateLimitReset() async throws {
        let session = FakeURLProtocol.session { _ in
            FakeResponse(status: 404, headers: [
                "X-RateLimit-Remaining": "4999", "X-RateLimit-Reset": "4102444800"
            ])
        }
        let client = GitHubClient(session: session) { "fake" }
        await #expect(throws: GitHubClientError.http(status: 404, retryAfter: nil)) {
            try await client.gist(id: "abc123")
        }
    }
}
