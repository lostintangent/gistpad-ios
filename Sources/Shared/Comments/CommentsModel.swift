import Foundation
import Observation

public protocol GitHubComments: Sendable {
    func listComments(gistID: String) async throws -> [GistComment]
    func createComment(gistID: String, body: String) async throws -> GistComment
    func updateComment(gistID: String, commentID: Int64, body: String) async throws -> GistComment
    func deleteComment(gistID: String, commentID: Int64) async throws
}

/// The open gist's comments and its one in-memory draft, shaped like the web's comments panel.
@MainActor @Observable
public final class CommentsModel {
    public enum Target: Equatable, Sendable {
        case root
        case quote(text: String, filename: String)
        case reply(Int64)
        case edit(GistComment)
    }

    public enum Failure: Equatable, Sendable {
        case load, post, delete
    }

    public let gistID: String
    public let userID: Int64
    public let gistOwnerID: Int64?
    public private(set) var comments: [GistComment]?
    public private(set) var isRefreshing = false
    public private(set) var isPosting = false
    public private(set) var failure: Failure?
    public private(set) var target = Target.root
    public var draft = ""

    @ObservationIgnored private let github: any GitHubComments
    @ObservationIgnored private var stashed = (target: Target.root, draft: "")

    public init(gistID: String, userID: Int64, gistOwnerID: Int64?, github: any GitHubComments) {
        self.gistID = gistID
        self.userID = userID
        self.gistOwnerID = gistOwnerID
        self.github = github
    }

    public var threads: [GistCommentThread] { GistCommentThread.build(from: comments ?? []) }

    public var canPost: Bool {
        !isPosting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            comments = try await github.listComments(gistID: gistID)
            if failure == .load { failure = nil }
        } catch {
            if !Task.isCancelled { failure = .load }
        }
    }

    public func beginQuote(_ text: String, filename: String) {
        finishEditing()
        target = .quote(text: text, filename: filename)
    }

    public func beginReply(to commentID: Int64) {
        finishEditing()
        target = .reply(commentID)
    }

    /// Editing borrows the composer, and the unsent comment returns when the edit ends.
    public func beginEditing(_ commentID: Int64) {
        guard let comment = comments?.first(where: { $0.id == commentID }) else { return }
        if case .edit = target {} else { stashed = (target, draft) }
        target = .edit(comment)
        draft = comment.parsedBody.text
    }

    public func removeContext() {
        if case .edit = target { finishEditing() } else { target = .root }
    }

    public func post() async {
        guard canPost else { return }
        isPosting = true
        defer { isPosting = false }
        let posting = target
        do {
            switch posting {
            case .root:
                try await create(draft)
            case .quote(let quote, _):
                try await create(GistCommentBody.quoting(quote, text: draft))
            case .reply(let parentID):
                try await create(GistCommentBody.replying(to: parentID, text: draft))
            case .edit(let comment):
                let updated = try await github.updateComment(
                    gistID: gistID, commentID: comment.id,
                    body: comment.parsedBody.replacingText(with: draft))
                comments = comments?.map { $0.id == updated.id ? updated : $0 }
            }
            failure = nil
            if case .edit = posting { finishEditing() } else { (target, draft) = (.root, "") }
        } catch {
            failure = .post
        }
    }

    public func delete(_ commentID: Int64) async {
        isPosting = true
        defer { isPosting = false }
        do {
            try await github.deleteComment(gistID: gistID, commentID: commentID)
            comments?.removeAll { $0.id == commentID }
            failure = nil
        } catch {
            failure = .delete
        }
    }

    private func create(_ body: String) async throws {
        // Awaiting inside `comments?.append(…)` would hold the observed mutation open across the
        // request, so views would re-read the old comments and miss the new one.
        let created = try await github.createComment(gistID: gistID, body: body)
        comments?.append(created)
    }

    private func finishEditing() {
        guard case .edit = target else { return }
        (target, draft) = stashed
        stashed = (.root, "")
    }
}
