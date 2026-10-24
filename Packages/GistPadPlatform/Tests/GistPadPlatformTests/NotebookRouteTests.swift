import Foundation
import Testing
@testable import GistPadPlatform

struct NotebookRouteTests {
    @Test(arguments: [
        "https://gistpad.dev/#/abc123",
        "https://gistpad.dev/abc123",
        "gistpad://note/abc123"
    ])
    func opensSavedNote(value: String) throws {
        #expect(try NotebookRoute(url: #require(URL(string: value))) ==
            .note(gistID: "abc123", filename: nil, shared: false))
    }

    @Test(arguments: [
        "https://gistpad.dev/#/share/abc123/%E6%97%A5%E8%A8%98%20%231%25.md?heading=hello",
        "https://gistpad.dev/share/abc123/%E6%97%A5%E8%A8%98%20%231%25.md",
        "gistpad://share/abc123/%E6%97%A5%E8%A8%98%20%231%25.md"
    ])
    func preservesExactFilename(value: String) throws {
        #expect(try NotebookRoute(url: #require(URL(string: value))) ==
            .note(gistID: "abc123", filename: "日記 #1%.md", shared: true))
    }

    @Test(arguments: [
        NotebookRoute.library, .today, .newNote, .addToToday,
        .note(gistID: "abc123", filename: "folder/name ?#%.md", shared: false),
        .note(gistID: "abc123", filename: "README.md", shared: true),
        .draft(
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            draftID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    ])
    func nativeRoutesRoundTrip(route: NotebookRoute) throws {
        #expect(try NotebookRoute(url: route.url) == route)
    }

    @Test(arguments: [
        "http://gistpad.dev/#/abc123",
        "https://gistpad.dev.evil.example/#/abc123",
        "https://gistpad.dev@evil.example/#/abc123",
        "https://user@gistpad.dev/#/abc123",
        "https://gistpad.dev:443/#/abc123",
        "https://gistpad.dev/other/#/abc123",
        "https://gistpad.dev/#access_token=secret",
        "https://gistpad.dev/#/share",
        "https://gistpad.dev/#/abc123/README.md/extra",
        "https://gistpad.dev/#/abc123//README.md",
        "https://gistpad.dev/#/abc%2F123",
        "https://gistpad.dev/#/abc123/%00.md",
        "gistpad://auth-callback?code=secret",
        "gistpad://draft/not-an-account/not-a-draft",
        "file:///abc123"
    ])
    func rejectsUnrelatedOrMalformedURLs(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: NotebookRouteError.self) { try NotebookRoute(url: url) }
    }

    @Test(arguments: [
        ("https://gistpad.dev/", NotebookRoute.library),
        ("https://gistpad.dev/#/", .library),
        ("https://gistpad.dev/#/today", .today),
        ("https://gistpad.dev/#/new", .newNote)
    ])
    func mapsWebActions(value: String, route: NotebookRoute) throws {
        #expect(try NotebookRoute(url: #require(URL(string: value))) == route)
    }
}
