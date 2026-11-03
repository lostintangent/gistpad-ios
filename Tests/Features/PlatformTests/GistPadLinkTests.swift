import Foundation
import Testing
@testable import Platform

struct GistPadLinkTests {
    @Test func everyLinkTheAppEmitsRoundTrips() throws {
        let links: [GistPadLink] = [
            .today, .addToToday, .newGist,
            .gist(id: "abc123", filename: nil),
            .gist(id: "abc123", filename: "日記 #1?%.md"),
            .unpublishedGist(accountID: UUID(), draftID: UUID())
        ]
        for link in links {
            #expect(GistPadLink(url: link.url) == link)
        }
        for value in ["gistpad://auth-callback?code=secret", "gistpad://draft/a/b", "https://gistpad.dev/#/abc123"] {
            #expect(GistPadLink(url: try #require(URL(string: value))) == nil)
        }
    }
}
