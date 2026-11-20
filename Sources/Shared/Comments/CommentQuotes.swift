import Foundation

public struct CommentQuote: Equatable, Sendable {
    public let threadID: Int64
    public let quote: String

    public init(threadID: Int64, quote: String) {
        self.threadID = threadID
        self.quote = quote
    }
}

public enum CommentQuoteMatcher {
    typealias Match = (threadID: Int64, segment: Int, range: NSRange)
    private static let minimumQuoteLength = 3
    private static let minimumSelectionLength = 4

    public static func isEligibleSelection(_ selection: String) -> Bool {
        selection.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= minimumSelectionLength
    }

    /// Like the web's `\bquote\b`, a quote links only when it appears exactly once as whole words.
    static func matches(quotes: [CommentQuote], segments: [String]) -> [Match] {
        let haystacks = segments.map { $0 as NSString }
        return quotes.compactMap { match($0, in: haystacks) }
    }

    /// One literal scan per quote, over haystacks built once. A second hit unlinks it, like the web.
    private static func match(_ quote: CommentQuote, in haystacks: [NSString]) -> Match? {
        let needle = quote.quote as NSString
        guard needle.length >= minimumQuoteLength else { return nil }
        var found: Match?
        for (segment, haystack) in haystacks.enumerated() {
            var location = 0
            while location < haystack.length {
                let rest = NSRange(location: location, length: haystack.length - location)
                let range = haystack.range(of: quote.quote, options: .literal, range: rest)
                guard range.location != NSNotFound else { break }
                if isWordBoundary(in: haystack, at: range.location),
                    isWordBoundary(in: haystack, at: NSMaxRange(range))
                {
                    if found != nil { return nil }
                    found = (quote.threadID, segment, range)
                }
                location = range.location + max(range.length, 1)
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
