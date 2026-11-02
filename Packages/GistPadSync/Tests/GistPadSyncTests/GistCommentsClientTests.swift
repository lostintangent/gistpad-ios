import Foundation
import GistPadComments
import Synchronization
import Testing
@testable import GistPadSync

@Suite struct GistCommentsClientTests {
    @Test func paginatesAllCommentsWithoutTheMarkdownGistFilter() async throws {
        let paths = Mutex<[String]>([])
        let session = FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            paths.withLock { $0.append(request.url!.absoluteString) }
            if request.url?.query?.contains("page=2") == true {
                return FakeResponse(data: try commentsData([2, 3], anonymous: true))
            }
            return FakeResponse(
                headers: ["Link": "<https://api.github.com/gists/abc123/comments?per_page=100&page=2>; rel=\"next\""],
                data: try commentsData([1, 2]))
        }
        let comments = try await GitHubClient(session: session) { "fake" }.listComments(gistID: "abc123")
        #expect(comments.map(\.id) == [1, 2, 3])
        #expect(comments.last?.user == nil)
        #expect(comments.first?.user?.avatarURL == URL(string: "https://avatars.githubusercontent.com/u/42"))
        #expect(comments.first?.createdAt == Date(timeIntervalSince1970: 1_792_785_600))
        #expect(paths.withLock { $0.count } == 2)
        #expect(paths.withLock { $0.first } == "https://api.github.com/gists/abc123/comments?per_page=100")
    }

    @Test func supportsGetCreateUpdateAndDeleteWithExactWireBodies() async throws {
        let calls = Mutex<[String]>([])
        let quoted = GistCommentBody.quoting("A **quoted** passage", text: "Comment\n\nBody")
        let reply = try GistCommentBody.replying(to: 123, text: "Reply")
        let session = FakeURLProtocol.session { request in
            calls.withLock { $0.append("\(request.httpMethod!) \(request.url!.path)") }
            switch request.httpMethod {
            case "POST":
                #expect(try requestBody(request)["body"] as? String == quoted)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                return FakeResponse(status: 201, data: try commentData(id: 123, body: quoted))
            case "PATCH":
                #expect(try requestBody(request)["body"] as? String == reply)
                return FakeResponse(data: try commentData(id: 123, body: reply))
            case "DELETE":
                return FakeResponse(status: 204)
            default:
                return FakeResponse(data: try commentData(id: 123, body: quoted))
            }
        }
        let client = GitHubClient(session: session) { "fake" }
        #expect(try await client.comment(gistID: "abc123", commentID: 123).body == quoted)
        #expect(try await client.createComment(gistID: "abc123", body: quoted).body == quoted)
        #expect(try await client.updateComment(gistID: "abc123", commentID: 123, body: reply).body == reply)
        try await client.deleteComment(gistID: "abc123", commentID: 123)
        #expect(calls.withLock { $0 } == [
            "GET /gists/abc123/comments/123", "POST /gists/abc123/comments",
            "PATCH /gists/abc123/comments/123", "DELETE /gists/abc123/comments/123"
        ])
    }

    @Test func unsafeCommentPaginationNeverForwardsCredentials() async throws {
        let calls = Mutex(0)
        let session = FakeURLProtocol.session { _ in
            calls.withLock { $0 += 1 }
            return FakeResponse(
                headers: ["Link": "<https://example.com/gists/abc123/comments?page=2>; rel=\"next\""],
                data: try commentsData([1]))
        }
        let client = GitHubClient(session: session) { "fake" }
        await #expect(throws: GitHubClientError.unsafeURL) {
            try await client.listComments(gistID: "abc123")
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aRepeatedCommentPageIsAnExplicitFailure() async throws {
        let session = FakeURLProtocol.session { _ in
            FakeResponse(
                headers: ["Link": "<https://api.github.com/gists/abc123/comments?per_page=100>; rel=\"next\""],
                data: try commentsData([1]))
        }
        let client = GitHubClient(session: session) { "fake" }
        await #expect(throws: GitHubClientError.invalidResponse) {
            try await client.listComments(gistID: "abc123")
        }
    }

    @Test func invalidIdentifiersFailBeforeRequestingCredentials() async throws {
        let calls = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            Issue.record("An invalid comment target must not reach the network")
            return FakeResponse()
        }) {
            calls.withLock { $0 += 1 }
            return "fake"
        }
        await #expect(throws: GitHubClientError.invalidIdentifier) {
            try await client.listComments(gistID: "../other")
        }
        await #expect(throws: GitHubClientError.invalidIdentifier) {
            try await client.createComment(gistID: "", body: "Body")
        }
        await #expect(throws: GitHubClientError.invalidIdentifier) {
            try await client.comment(gistID: "abc123", commentID: 0)
        }
        await #expect(throws: GitHubClientError.invalidIdentifier) {
            try await client.updateComment(gistID: "abc123", commentID: -1, body: "Body")
        }
        await #expect(throws: GitHubClientError.invalidIdentifier) {
            try await client.deleteComment(gistID: "abc123", commentID: -1)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [403, 404, 422, 429, 503])
    func commentFailuresPropagateWithoutRetryingOrPretendingTheListIsEmpty(status: Int) async throws {
        let calls = Mutex(0)
        let session = FakeURLProtocol.session { _ in
            calls.withLock { $0 += 1 }
            return FakeResponse(status: status)
        }
        let client = GitHubClient(session: session) { "fake" }
        do {
            _ = try await client.createComment(gistID: "abc123", body: "Body")
            Issue.record("Expected a typed GitHub failure")
        } catch GitHubClientError.http(let actual, _) {
            #expect(actual == status)
        }
        #expect(calls.withLock { $0 } == 1)
        do {
            _ = try await client.listComments(gistID: "abc123")
            Issue.record("A failed read must not become an empty list")
        } catch GitHubClientError.http(let actual, _) {
            #expect(actual == status)
        }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func uncertainCommentCreationIsNeverAutomaticallyRetried() async throws {
        let calls = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }) { "fake" }
        await #expect(throws: URLError.self) {
            try await client.createComment(gistID: "abc123", body: "Body")
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func gistCommentCountsKeepUnknownDistinctFromKnownEmpty() throws {
        let data = try gistData()
        #expect(try decodeGist(data).commentCount == nil)
        for count in [0, 4] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["comments"] = count
            let gist = try decodeGist(JSONSerialization.data(withJSONObject: object))
            #expect(gist.commentCount == count)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            #expect(try decodeGist(encoder.encode(gist)).commentCount == count)
        }
    }
}

private func commentData(id: Int64, body: String = "Body", anonymous: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": id, "body": body,
        "user": anonymous ? NSNull() : [
            "id": 42, "login": "author", "avatar_url": "https://avatars.githubusercontent.com/u/42"
        ],
        "created_at": "2026-10-23T20:00:00Z", "updated_at": "2026-10-24T20:00:00Z"
    ])
}

private func commentsData(_ ids: [Int64], anonymous: Bool = false) throws -> Data {
    let comments = try ids.map { try JSONSerialization.jsonObject(with: commentData(id: $0, anonymous: anonymous)) }
    return try JSONSerialization.data(withJSONObject: comments)
}
