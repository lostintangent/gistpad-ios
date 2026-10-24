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

    public static func build(from comments: [GistComment]) -> [GistCommentThread] {
        let comments = GistComment.latestVersions(in: comments)
        let unique = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
        var order = comments.map(\.id)
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        order.sort {
            let left = unique[$0]!, right = unique[$1]!
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return positions[$0]! < positions[$1]!
        }
        var parents: [Int64: Int64] = [:]
        for id in order {
            if let parent = unique[id]!.parsedBody.parentID, parent != id, unique[parent] != nil {
                parents[id] = parent
            }
        }

        // Malformed cycles must not make the whole conversation disappear.
        var resolved: Set<Int64> = []
        for id in order {
            var path: Set<Int64> = []
            var current: Int64? = id
            while let next = current, !resolved.contains(next) {
                guard path.insert(next).inserted else {
                    parents.removeValue(forKey: next)
                    break
                }
                current = parents[next]
            }
            resolved.formUnion(path)
        }

        var depths: [Int64: Int] = [:]
        var displayedParents: [Int64: Int64] = [:]
        for id in order where depths[id] == nil {
            var path: [Int64] = []
            var current: Int64? = id
            while let next = current, depths[next] == nil {
                path.append(next)
                current = parents[next]
            }
            for next in path.reversed() {
                if let parent = parents[next] {
                    let depth = depths[parent]!
                    // Preserve deeper imported replies at the last supported visual level.
                    displayedParents[next] = depth < maximumReplyDepth
                        ? parent : displayedParents[parent]
                    depths[next] = min(depth + 1, maximumReplyDepth)
                } else {
                    depths[next] = 0
                }
            }
        }
        var children: [Int64: [Int64]] = [:]
        var roots: [Int64] = []
        for id in order {
            if let parent = displayedParents[id] {
                children[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }
        func thread(_ id: Int64) -> GistCommentThread {
            GistCommentThread(
                comment: unique[id]!, replies: (children[id] ?? []).map(thread), depth: depths[id]!)
        }
        return roots.map(thread)
    }
}
