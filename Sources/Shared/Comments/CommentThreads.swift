import Foundation

public struct GistCommentThread: Equatable, Identifiable, Sendable {
    public static let maximumReplyDepth = 2
    public let comment: GistComment
    public let replies: [GistCommentThread]
    public let depth: Int
    public var id: Int64 { comment.id }
    public var canReply: Bool { depth < Self.maximumReplyDepth }

    public var quotedPassage: CommentQuote? {
        guard let quote = comment.parsedBody.quote, !quote.isEmpty else { return nil }
        return CommentQuote(commentID: id, quote: quote)
    }

    /// Threads sort newest first, and a reply whose parent is gone becomes a thread of its own.
    public static func build(from comments: [GistComment]) -> [GistCommentThread] {
        let ids = Set(comments.map(\.id))
        var roots: [GistComment] = []
        var replies: [Int64: [GistComment]] = [:]
        for comment in comments.enumerated().sorted(by: {
            $0.element.createdAt != $1.element.createdAt
                ? $0.element.createdAt > $1.element.createdAt : $0.offset < $1.offset
        }).map(\.element) {
            if let parentID = comment.parsedBody.parentID, ids.contains(parentID) {
                replies[parentID, default: []].append(comment)
            } else {
                roots.append(comment)
            }
        }
        func thread(_ comment: GistComment, depth: Int) -> GistCommentThread {
            GistCommentThread(
                comment: comment,
                replies: (replies[comment.id] ?? []).map { thread($0, depth: depth + 1) },
                depth: depth)
        }
        return roots.map { thread($0, depth: 0) }
    }
}
