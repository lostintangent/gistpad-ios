import Foundation

/// The passages a note's comments quote, and what tapping, linking and adding one does. A surface
/// without highlights has no comments.
public struct CommentHighlights: Sendable {
    public var quotes: [CommentQuote]
    public var selectedThreadID: Int64?
    /// Changes when the selected thread should scroll into view again.
    public var revealRevision: UInt64
    public var showsInlineComments: Bool
    /// Opens the threads under a tapped passage.
    public var open: @MainActor ([Int64]) -> Void
    /// Reports which threads still find their passage in the text.
    public var linked: @MainActor (Set<Int64>) -> Void
    /// Starts a thread that quotes the selected text.
    public var add: @MainActor (String) -> Void

    public init(
        quotes: [CommentQuote] = [], selectedThreadID: Int64? = nil, revealRevision: UInt64 = 0,
        showsInlineComments: Bool = true, open: @escaping @MainActor ([Int64]) -> Void,
        linked: @escaping @MainActor (Set<Int64>) -> Void, add: @escaping @MainActor (String) -> Void
    ) {
        self.quotes = quotes
        self.selectedThreadID = selectedThreadID
        self.revealRevision = revealRevision
        self.showsInlineComments = showsInlineComments
        self.open = open
        self.linked = linked
        self.add = add
    }
}

extension CommentHighlights: Equatable {
    /// Two values are equal when they show the same highlights. Every view update makes new
    /// closures, so they never count.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.quotes == rhs.quotes && lhs.selectedThreadID == rhs.selectedThreadID
            && lhs.revealRevision == rhs.revealRevision && lhs.showsInlineComments == rhs.showsInlineComments
    }
}

public struct CommentQuoteHighlight: Equatable, Sendable {
    public let segment: Int
    public let start: Int
    public let end: Int
    public let threadIDs: [Int64]
    public var range: NSRange { NSRange(location: start, length: end - start) }
}

extension [CommentQuote] {
    public func highlights(in segments: [String]) -> [CommentQuoteHighlight] {
        let matches = matches(in: segments)
        let grouped = Dictionary(grouping: matches, by: \.segment)
        var highlights: [CommentQuoteHighlight] = []
        for (segment, matches) in grouped.sorted(by: { $0.key < $1.key }) {
            let boundaries = Set(matches.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                var seen: Set<Int64> = []
                let ids = matches.compactMap { match -> Int64? in
                    guard match.range.location <= start, NSMaxRange(match.range) >= end,
                          seen.insert(match.threadID).inserted else { return nil }
                    return match.threadID
                }
                guard !ids.isEmpty else { continue }
                if let previous = highlights.last, previous.segment == segment,
                   previous.end == start, previous.threadIDs == ids {
                    highlights[highlights.count - 1] = CommentQuoteHighlight(
                        segment: segment, start: previous.start, end: end, threadIDs: ids)
                } else {
                    highlights.append(CommentQuoteHighlight(
                        segment: segment, start: start, end: end, threadIDs: ids))
                }
            }
        }
        return highlights
    }
}
