import Foundation
import Testing
@testable import GistPadPlatform

struct NotebookRouteTests {
    @Test func everyRouteTheAppEmitsRoundTrips() throws {
        let routes: [NotebookRoute] = [
            .today, .addToToday,
            .note(gistID: "abc123", filename: nil),
            .note(gistID: "abc123", filename: "日記 #1?%.md"),
            .draft(accountID: UUID(), draftID: UUID())
        ]
        for route in routes {
            #expect(NotebookRoute(url: route.url) == route)
        }
        for value in ["gistpad://auth-callback?code=secret", "gistpad://draft/a/b", "https://gistpad.dev/#/abc123"] {
            #expect(NotebookRoute(url: try #require(URL(string: value))) == nil)
        }
    }
}
