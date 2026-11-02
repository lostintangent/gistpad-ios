import Foundation
import Testing
@testable import GistPadComments

struct CommentQuoteHighlightTests {
    @Test func overlappingPassagesRetainEveryThreadInInputOrder() {
        let spans = CommentQuoteMatcher.highlights(
            quotes: [
                CommentQuote(commentID: 10, quote: "one two"),
                CommentQuote(commentID: 20, quote: "two three")
            ],
            segments: ["one two three"])
        #expect(spans.map(\.range) == [
            NSRange(location: 0, length: 4),
            NSRange(location: 4, length: 3),
            NSRange(location: 7, length: 6)
        ])
        #expect(spans.map(\.commentIDs) == [[10], [10, 20], [20]])
    }

    @Test func missingRepeatedAndShortQuotesStayUnlinked() {
        let spans = CommentQuoteMatcher.highlights(
            quotes: [
                CommentQuote(commentID: 10, quote: "native"),
                CommentQuote(commentID: 20, quote: "missing"),
                CommentQuote(commentID: 30, quote: "na")
            ],
            segments: ["native", "native"])
        #expect(spans.isEmpty)
    }
}
