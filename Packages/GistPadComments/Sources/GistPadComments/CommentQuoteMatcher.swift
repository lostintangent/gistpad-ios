import Foundation

public struct CommentQuote: Codable, Equatable, Sendable {
    public let commentID: Int64
    public let quote: String

    public init(commentID: Int64, quote: String) {
        self.commentID = commentID
        self.quote = quote
    }
}

public struct CommentQuoteMatch: Codable, Equatable, Sendable {
    public let commentID: Int64
    public let segment: Int
    public let start: Int
    public let end: Int
    public var range: NSRange { NSRange(location: start, length: end - start) }
}

public enum CommentQuoteMatcher {
    public static let minimumQuoteLength = 3
    public static let minimumSelectionLength = 4

    public static func isEligibleSelection(_ selection: String) -> Bool {
        GistCommentBody.trim(selection).utf16.count >= minimumSelectionLength
    }

    public static func matches(
        quotes: [CommentQuote], segments: [String]
    ) -> [CommentQuoteMatch] {
        let texts = segments.map { $0 as NSString }
        return quotes.compactMap { quote in
            let length = quote.quote.utf16.count
            guard length >= minimumQuoteLength else { return nil }
            var match: CommentQuoteMatch?
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
                        match = CommentQuoteMatch(
                            commentID: quote.commentID, segment: segment,
                            start: range.location, end: end)
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
