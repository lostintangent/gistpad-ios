import Foundation
import Testing
@testable import GistPadComments

struct CommentQuoteHighlightTests {
    @Test func quoteEqualityPreservesLiteralUTF16ForHighlightCaches() {
        let composed = CommentQuote(commentID: 10, quote: "café note")
        let decomposed = CommentQuote(commentID: 10, quote: "cafe\u{0301} note")
        #expect(composed != decomposed)
        #expect(
            CommentHighlightConfiguration(quotes: [composed])
                != CommentHighlightConfiguration(quotes: [decomposed]))
        #expect(CommentQuoteMatcher.matches(quotes: [composed], segments: ["café note"]).count == 1)
        #expect(CommentQuoteMatcher.matches(quotes: [decomposed], segments: ["café note"]).isEmpty)
    }

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

    @Test func nestedPassagesDoNotChooseAnArbitraryThread() {
        let spans = CommentQuoteMatcher.highlights(
            quotes: [
                CommentQuote(commentID: 10, quote: "A careful native note"),
                CommentQuote(commentID: 20, quote: "careful native")
            ],
            segments: ["A careful native note."])
        #expect(spans.map(\.range) == [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 14),
            NSRange(location: 16, length: 5)
        ])
        #expect(spans.map(\.commentIDs) == [[10], [10, 20], [10]])
    }

    @Test func identicalPassagesShareOneHighlightWithoutDuplicateIDs() {
        let spans = CommentQuoteMatcher.highlights(
            quotes: [
                CommentQuote(commentID: 30, quote: "native"),
                CommentQuote(commentID: 10, quote: "native"),
                CommentQuote(commentID: 30, quote: "native")
            ],
            segments: ["A native note"])
        #expect(spans.count == 1)
        #expect(spans.first?.commentIDs == [30, 10])
        #expect(spans.first?.range == NSRange(location: 2, length: 6))
    }

    @Test func segmentsAndUTF16OffsetsRemainExact() {
        let spans = CommentQuoteMatcher.highlights(
            quotes: [
                CommentQuote(commentID: 10, quote: "native"),
                CommentQuote(commentID: 20, quote: "thought")
            ],
            segments: ["🫧 native note", "A thought to keep"])
        #expect(spans.map(\.segment) == [0, 1])
        #expect(spans.map(\.range) == [
            NSRange(location: 3, length: 6), NSRange(location: 2, length: 7)
        ])
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
