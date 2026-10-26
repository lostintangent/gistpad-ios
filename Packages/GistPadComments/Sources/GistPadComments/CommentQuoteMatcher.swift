import Foundation

public struct CommentQuote: Equatable, Sendable {
    public let commentID: Int64
    public let quote: String

    public init(commentID: Int64, quote: String) {
        self.commentID = commentID
        self.quote = quote
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.commentID == rhs.commentID && lhs.quote.utf16.elementsEqual(rhs.quote.utf16)
    }
}

public enum CommentQuoteMatcher {
    typealias Match = (commentID: Int64, segment: Int, range: NSRange)
    private static let minimumQuoteLength = 3
    private static let minimumSelectionLength = 4

    public static func isEligibleSelection(_ selection: String) -> Bool {
        GistCommentBody.trim(selection).utf16.count >= minimumSelectionLength
    }

    static func matches(
        quotes: [CommentQuote], segments: [String]
    ) -> [Match] {
        let texts = segments.map { $0 as NSString }
        return quotes.compactMap { quote in
            let length = quote.quote.utf16.count
            guard length >= minimumQuoteLength else { return nil }
            var match: Match?
            for (segment, text) in texts.enumerated() {
                var location = 0
                while location <= text.length - length {
                    let range = text.range(
                        of: quote.quote, options: .literal,
                        range: NSRange(location: location, length: text.length - location))
                    guard range.location != NSNotFound else { break }
                    let end = NSMaxRange(range)
                    if isWordBoundary(range.location, in: text), isWordBoundary(end, in: text) {
                        guard match == nil else { return nil }
                        match = (commentID: quote.commentID, segment: segment, range: range)
                        location = end
                    } else {
                        location = range.location + 1
                    }
                }
            }
            return match
        }
    }

    private static func isWordBoundary(_ index: Int, in text: NSString) -> Bool {
        let before = index > 0 && isWord(text.character(at: index - 1))
        let after = index < text.length && isWord(text.character(at: index))
        return before != after
    }

    private static func isWord(_ unit: UInt16) -> Bool {
        // JavaScript's non-Unicode \b uses ASCII \w, not ICU's Unicode word boundaries.
        (48...57).contains(unit) || (65...90).contains(unit)
            || (97...122).contains(unit) || unit == 95
    }
}
