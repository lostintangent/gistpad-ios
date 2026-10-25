import Foundation
import GistPadComments

public struct GitHubCommentRemote: CommentConversationRemote {
    private let client: GitHubClient

    public init(client: GitHubClient) { self.client = client }

    public func listComments(gistID: String) async throws(CommentRemoteFailure) -> [GistComment] {
        do { return try await client.listComments(gistID: gistID) }
        catch { throw Self.failure(error) }
    }

    public func comment(
        gistID: String, commentID: Int64
    ) async throws(CommentRemoteFailure) -> GistComment {
        do { return try await client.comment(gistID: gistID, commentID: commentID) }
        catch { throw Self.failure(error) }
    }

    public func createComment(
        gistID: String, body: String
    ) async throws(CommentRemoteFailure) -> GistComment {
        do { return try await client.createComment(gistID: gistID, body: body) }
        catch { throw Self.failure(error) }
    }

    public func updateComment(
        gistID: String, commentID: Int64, body: String
    ) async throws(CommentRemoteFailure) -> GistComment {
        do { return try await client.updateComment(gistID: gistID, commentID: commentID, body: body) }
        catch { throw Self.failure(error) }
    }

    public func deleteComment(
        gistID: String, commentID: Int64
    ) async throws(CommentRemoteFailure) {
        do { try await client.deleteComment(gistID: gistID, commentID: commentID) }
        catch { throw Self.failure(error) }
    }

    private static func failure(_ error: any Error) -> CommentRemoteFailure {
        if error is AccountError { return .authentication }
        if let error = error as? GitHubClientError {
            switch error {
            case .invalidIdentifier, .unsafeURL: return .invalidRequest
            case .http(let status, let deadline):
                if deadline != nil { return .http(status: status, retryAfter: deadline) }
                switch status {
                case 401: return .authentication
                case 403: return .forbidden
                case 404: return .notFound
                default: return .http(status: status, retryAfter: nil)
                }
            default: return .invalidResponse
            }
        }
        if error is URLError || error is CancellationError { return .network }
        return .invalidResponse
    }
}
