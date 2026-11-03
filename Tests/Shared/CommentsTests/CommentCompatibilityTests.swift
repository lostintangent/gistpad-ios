import Foundation
import Testing
@testable import Comments

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
                CommentCompatibilityFixtures.Quote.Match(
                    segment: $0.segment, start: $0.range.location, end: NSMaxRange($0.range))
            } == fixture.matches, Comment(rawValue: fixture.quote))
            #expect(actual.allSatisfy { $0.commentID == 7 })
            for match in actual {
                #expect((fixture.segments[match.segment] as NSString).substring(with: match.range) == fixture.quote)
            }
        }
    }

    @Test func createsWebCompatibleQuoteAndReplyBodies() {
        let quoted = GistCommentBody.quoting("first line\nsecond line", text: "Feedback")
        #expect(quoted == "> first line\nsecond line\n\nFeedback")
        #expect(GistCommentBody(quoted).quote == "first line")
        #expect(GistCommentBody(quoted).text == "second line\n\nFeedback")
        let reply = GistCommentBody.replying(to: 123, text: "Reply")
        #expect(reply == "> [comment:123]\n\nReply")
        #expect(GistCommentBody(reply).parentID == 123)
    }
}
