import Foundation

public struct CommentQuote: Equatable, Sendable {
    /// Where quoted text sits in one segment, and every thread that quotes it, in input order.
    public struct Match: Equatable, Sendable {
        public let segment: Int
        public let start: Int
        public let end: Int
        public let threadIDs: [Int64]
        public var range: NSRange { NSRange(location: start, length: end - start) }
    }

    fileprivate typealias Occurrence = (threadID: Int64, segment: Int, range: NSRange)
    private static let minimumQuoteLength = 3
    private static let minimumSelectionLength = 4

    public let threadID: Int64
    public let quote: String

    public init(threadID: Int64, quote: String) {
        self.threadID = threadID
        self.quote = quote
    }

    public static func isQuotable(_ selection: String) -> Bool {
        selection.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= minimumSelectionLength
    }

    /// One literal scan per quote, over haystacks built once. A second hit unlinks it, like the web.
    fileprivate func occurrence(in haystacks: [NSString]) -> Occurrence? {
        let needle = quote as NSString
        guard needle.length >= Self.minimumQuoteLength else { return nil }
        let checksStart = Self.isASCIIWord(needle.character(at: 0))
        let checksEnd = Self.isASCIIWord(needle.character(at: needle.length - 1))
        var found: Occurrence?
        for (segment, haystack) in haystacks.enumerated() {
            var location = 0
            while location < haystack.length {
                let rest = NSRange(location: location, length: haystack.length - location)
                let range = haystack.range(of: quote, options: .literal, range: rest)
                guard range.location != NSNotFound else { break }
                if !checksStart || Self.isWordBoundary(in: haystack, at: range.location),
                    !checksEnd || Self.isWordBoundary(in: haystack, at: NSMaxRange(range))
                {
                    if found != nil { return nil }
                    found = (threadID, segment, range)
                    location = range.location + range.length
                } else {
                    location = range.location + 1
                }
            }
        }
        return found
    }

    /// JS `\b` with ASCII `\w`: a boundary sits between a word unit and a non-word unit.
    private static func isWordBoundary(in text: NSString, at index: Int) -> Bool {
        let previous = index > 0 && isASCIIWord(text.character(at: index - 1))
        let next = index < text.length && isASCIIWord(text.character(at: index))
        return previous != next
    }

    private static func isASCIIWord(_ unit: unichar) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
            || unit == 95
    }
}

extension [CommentQuote] {
    /// Like the web, a quote links only when it appears exactly once, with a word boundary at each
    /// edge that ends in a word character, so "ship it." links but "care" never matches "careful".
    /// Overlapping quotes split into pieces that list every thread quoting them.
    public func matches(in segments: [String]) -> [CommentQuote.Match] {
        let haystacks = segments.map { $0 as NSString }
        let grouped = Dictionary(grouping: compactMap { $0.occurrence(in: haystacks) }, by: \.segment)
        var matches: [CommentQuote.Match] = []
        for (segment, occurrences) in grouped.sorted(by: { $0.key < $1.key }) {
            let boundaries = Set(occurrences.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                var seen: Set<Int64> = []
                let ids = occurrences.compactMap { occurrence -> Int64? in
                    guard occurrence.range.location <= start, NSMaxRange(occurrence.range) >= end,
                          seen.insert(occurrence.threadID).inserted else { return nil }
                    return occurrence.threadID
                }
                guard !ids.isEmpty else { continue }
                if let previous = matches.last, previous.segment == segment,
                   previous.end == start, previous.threadIDs == ids {
                    matches[matches.count - 1] = CommentQuote.Match(
                        segment: segment, start: previous.start, end: end, threadIDs: ids)
                } else {
                    matches.append(CommentQuote.Match(
                        segment: segment, start: start, end: end, threadIDs: ids))
                }
            }
        }
        return matches
    }
}
