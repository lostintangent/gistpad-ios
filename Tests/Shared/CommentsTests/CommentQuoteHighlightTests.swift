import Foundation
import Testing
@testable import Comments

struct CommentQuoteHighlightTests {
    @Test func overlappingPassagesRetainEveryThreadInInputOrder() {
        let spans = [
            CommentQuote(threadID: 10, quote: "one two"),
            CommentQuote(threadID: 20, quote: "two three")
        ].highlights(in: ["one two three"])
        #expect(spans.map(\.range) == [
            NSRange(location: 0, length: 4),
            NSRange(location: 4, length: 3),
            NSRange(location: 7, length: 6)
        ])
        #expect(spans.map(\.threadIDs) == [[10], [10, 20], [20]])
    }

    @Test func missingRepeatedAndShortQuotesStayUnlinked() {
        let spans = [
            CommentQuote(threadID: 10, quote: "native"),
            CommentQuote(threadID: 20, quote: "missing"),
            CommentQuote(threadID: 30, quote: "na")
        ].highlights(in: ["native", "native"])
        #expect(spans.isEmpty)
    }

    @Test func aRejectedHitStillFindsAnOverlappingMatch() {
        let spans = [CommentQuote(threadID: 10, quote: "a.a")].highlights(in: ["xa.a.a!"])
        #expect(spans.map(\.range) == [NSRange(location: 3, length: 3)])
    }

    @Test func twentyFourUniqueQuotesEachLinkOnce() {
        let quotes = (1...24).map { CommentQuote(threadID: Int64($0), quote: "quote\($0)token") }
        let note = quotes.map(\.quote).joined(separator: " and ") + "\n" + String(repeating: "Keep the useful things close. ", count: 280)
        let spans = quotes.highlights(in: [note])
        #expect(Set(spans.flatMap(\.threadIDs)) == Set(1...24))
    }
}
