import Foundation
import GistPadComments
import Synchronization
import Testing
@testable import GistPadSync

struct GitHubCommentRemoteTests {
    @Test(arguments: [401, 404, 408, 422, 503])
    func preservesTypedReadAndMutationFailures(status: Int) async {
        let session = FakeURLProtocol.session { _ in FakeResponse(status: status) }
        let remote = GitHubCommentRemote(client: GitHubClient(session: session) { "fake" })
        let expected: CommentRemoteFailure = switch status {
        case 401: .authentication
        case 404: .notFound
        default: .http(status: status, retryAfter: nil)
        }
        await #expect(throws: expected) { try await remote.listComments(gistID: "a123") }
        await #expect(throws: expected) {
            try await remote.createComment(gistID: "a123", body: "Synthetic body")
        }
    }

    @Test(arguments: [403, 429])
    func preservesServerRetryDeadlines(status: Int) async {
        let deadline = Date(timeIntervalSince1970: 1_900_000_000)
        let session = FakeURLProtocol.session { _ in
            FakeResponse(status: status, headers: [
                "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1900000000"
            ])
        }
        let remote = GitHubCommentRemote(client: GitHubClient(session: session) { "fake" })
        await #expect(throws: CommentRemoteFailure.http(status: status, retryAfter: deadline)) {
            try await remote.deleteComment(gistID: "a123", commentID: 1)
        }
    }

    @Test func lostTransportAcknowledgmentIsNotRetried() async {
        let calls = Mutex(0)
        let session = FakeURLProtocol.session { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }
        let remote = GitHubCommentRemote(client: GitHubClient(session: session) { "fake" })
        await #expect(throws: CommentRemoteFailure.network) {
            try await remote.createComment(gistID: "a123", body: "Synthetic body")
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func malformedReceiptsAreNotDefiniteRejections() async {
        let session = FakeURLProtocol.session { _ in
            FakeResponse(status: 201, data: Data("{}".utf8))
        }
        let remote = GitHubCommentRemote(client: GitHubClient(session: session) { "fake" })
        await #expect(throws: CommentRemoteFailure.invalidResponse) {
            try await remote.createComment(gistID: "a123", body: "Synthetic body")
        }
    }

    @Test func accountChangesAreDefiniteAuthenticationFailures() async {
        let remote = GitHubCommentRemote(client: GitHubClient { throw AccountError.accountChanged })
        await #expect(throws: CommentRemoteFailure.authentication) {
            try await remote.createComment(gistID: "a123", body: "Never sent")
        }
    }
}
