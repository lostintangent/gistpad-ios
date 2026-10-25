import Foundation

public struct CommentHighlightConfiguration: Equatable, Sendable {
    public var quotes: [CommentQuote]
    public var selectedCommentID: Int64?
    public var revealRevision: UInt64
    public var showsInlineComments: Bool

    public init(
        quotes: [CommentQuote] = [], selectedCommentID: Int64? = nil, revealRevision: UInt64 = 0,
        showsInlineComments: Bool = true
    ) {
        self.quotes = quotes
        self.selectedCommentID = selectedCommentID
        self.revealRevision = revealRevision
        self.showsInlineComments = showsInlineComments
    }
}

public struct CommentQuoteHighlight: Codable, Equatable, Sendable {
    public let segment: Int
    public let start: Int
    public let end: Int
    public let commentIDs: [Int64]
    public var range: NSRange { NSRange(location: start, length: end - start) }
}

extension CommentQuoteMatcher {
    public static func highlights(
        quotes: [CommentQuote], segments: [String]
    ) -> [CommentQuoteHighlight] {
        let matches = matches(quotes: quotes, segments: segments)
        let grouped = Dictionary(grouping: matches, by: \.segment)
        var highlights: [CommentQuoteHighlight] = []
        for segment in grouped.keys.sorted() {
            guard let matches = grouped[segment] else {
                preconditionFailure("A grouped quote segment must contain its matches.")
            }
            let boundaries = Set(matches.flatMap { [$0.start, $0.end] }).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                var seen: Set<Int64> = []
                let ids = matches.compactMap { match -> Int64? in
                    guard match.start <= start, match.end >= end,
                          seen.insert(match.commentID).inserted else { return nil }
                    return match.commentID
                }
                guard !ids.isEmpty else { continue }
                if let previous = highlights.last, previous.segment == segment,
                   previous.end == start, previous.commentIDs == ids {
                    highlights[highlights.count - 1] = CommentQuoteHighlight(
                        segment: segment, start: previous.start, end: end, commentIDs: ids)
                } else {
                    highlights.append(CommentQuoteHighlight(
                        segment: segment, start: start, end: end, commentIDs: ids))
                }
            }
        }
        return highlights
    }
}
