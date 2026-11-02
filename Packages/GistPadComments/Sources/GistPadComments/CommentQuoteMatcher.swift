import Foundation
import RegexBuilder

public struct CommentQuote: Equatable, Sendable {
    public let commentID: Int64
    public let quote: String

    public init(commentID: Int64, quote: String) {
        self.commentID = commentID
        self.quote = quote
    }
}

public enum CommentQuoteMatcher {
    typealias Match = (commentID: Int64, segment: Int, range: NSRange)
    private static let minimumQuoteLength = 3
    private static let minimumSelectionLength = 4

    public static func isEligibleSelection(_ selection: String) -> Bool {
        selection.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= minimumSelectionLength
    }

    /// Like the web's `\bquote\b`, a quote links only when it appears exactly once as whole words.
    static func matches(quotes: [CommentQuote], segments: [String]) -> [Match] {
        quotes.compactMap { quote in
            guard quote.quote.utf16.count >= minimumQuoteLength else { return nil }
            let pattern = Regex {
                Anchor.wordBoundary
                quote.quote
                Anchor.wordBoundary
            }
            .wordBoundaryKind(.simple).asciiOnlyWordCharacters().matchingSemantics(.unicodeScalar)
            let found = segments.enumerated().flatMap { segment, text in
                text.matches(of: pattern).map {
                    (commentID: quote.commentID, segment: segment, range: NSRange($0.range, in: text))
                }
            }
            return found.count == 1 ? found[0] : nil
        }
    }
}
