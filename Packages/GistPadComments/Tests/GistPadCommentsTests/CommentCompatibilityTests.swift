import Foundation
import Testing
@testable import GistPadComments

struct CommentCompatibilityFixtures: Decodable {
    struct Body: Decodable {
        let body: String
        let prefix: String
        let quote: String?
        let parentID: Int64?
        let text: String
    }
    struct Quote: Decodable {
        struct Match: Decodable, Equatable {
            let segment: Int
            let start: Int
            let end: Int
        }
        let quote: String
        let segments: [String]
        let matches: [Match]
    }
    let bodies: [Body]
    let quotes: [Quote]

    static func load() throws -> Self {
        let url = try #require(
            Bundle.module.url(forResource: "WebCompatibility", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@Suite struct CommentCompatibilityTests {
    @Test func parsesWebPrefixesWithoutChangingStoredBytes() throws {
        for fixture in try CommentCompatibilityFixtures.load().bodies {
            let parsed = GistCommentBody(fixture.body)
            #expect(Array(parsed.prefix.utf8) == Array(fixture.prefix.utf8))
            #expect(parsed.quote == fixture.quote)
            #expect(parsed.parentID == fixture.parentID)
            #expect(Array(parsed.text.utf8) == Array(fixture.text.utf8))
            #expect(parsed.replacingText(with: "Edited") == fixture.prefix + "Edited")
        }
    }

    @Test func matchesWebLiteralWordBoundariesAndUTF16Offsets() throws {
        for fixture in try CommentCompatibilityFixtures.load().quotes {
            let actual = CommentQuoteMatcher.matches(
                quotes: [.init(commentID: 7, quote: fixture.quote)], segments: fixture.segments)
            #expect(actual.map {
                CommentCompatibilityFixtures.Quote.Match(segment: $0.segment, start: $0.start, end: $0.end)
            } == fixture.matches, Comment(rawValue: fixture.quote))
            #expect(actual.allSatisfy { $0.commentID == 7 })
            for match in actual {
                #expect((fixture.segments[match.segment] as NSString).substring(with: match.range) == fixture.quote)
            }
        }
    }

    @Test func preservesOverlapsAndMultipleThreadsOnTheSamePassage() {
        let quotes: [CommentQuote] = [
            .init(commentID: 1, quote: "the passage"),
            .init(commentID: 2, quote: "passage here"),
            .init(commentID: 3, quote: "the passage")
        ]
        let matches = CommentQuoteMatcher.matches(quotes: quotes, segments: ["the passage here"])
        #expect(matches.map(\.commentID) == [1, 2, 3])
        #expect(matches[0].range == matches[2].range)
        #expect(NSIntersectionRange(matches[0].range, matches[1].range).length > 0)
    }

    @Test func createsWebCompatibleQuoteAndReplyBodies() throws {
        let quoted = GistCommentBody.quoting("first line\nsecond line", text: "Feedback")
        #expect(quoted == "> first line\nsecond line\n\nFeedback")
        #expect(GistCommentBody(quoted).quote == "first line")
        #expect(GistCommentBody(quoted).text == "second line\n\nFeedback")
        let reply = try GistCommentBody.replying(to: 123, text: "Reply")
        #expect(reply == "> [comment:123]\n\nReply")
        #expect(GistCommentBody(reply).parentID == 123)
        #expect(throws: GistCommentBodyError.invalidParentID) {
            try GistCommentBody.replying(to: 0, text: "Reply")
        }
    }

    @Test func selectionEligibilityUsesTheWebsTrimAndUTF16LengthWithoutChangingTheQuote() {
        #expect(!CommentQuoteMatcher.isEligibleSelection(" cat "))
        #expect(CommentQuoteMatcher.isEligibleSelection(" word "))
        #expect(!CommentQuoteMatcher.isEligibleSelection("\u{FEFF}cat\u{FEFF}"))
        #expect(CommentQuoteMatcher.isEligibleSelection("\u{85}cat"))
        #expect(CommentQuoteMatcher.isEligibleSelection("\u{1F600}ab"))
        let quote = "  exact selection  "
        #expect(CommentQuoteMatcher.isEligibleSelection(quote))
        #expect(GistCommentBody.quoting(quote, text: "Body").hasPrefix("> " + quote + "\n\n"))
    }

    @Test func anUnrepresentableReplyTargetNeverBecomesAQuotedPassageOrAnotherParent() {
        let body = GistCommentBody("> [comment:999999999999999999999999999999999]\n\nReply")
        #expect(body.isReply)
        #expect(body.parentID == nil)
        #expect(body.quote == nil)
        #expect(body.text == "Reply")
    }
}
