import Foundation
import Testing

@testable import Editor

struct FrontMatterRangeTests {
    @Test(arguments: [
        ("---\nkey: value\n---\n\n\n# Body", "---\nkey: value\n---\n\n\n"),
        ("--- \r\nkey: 日本語 👩🏽‍💻\r\n---\t\r\n \t\r\nBody", "--- \r\nkey: 日本語 👩🏽‍💻\r\n---\t\r\n \t\r\n"),
        ("---\nkey: value\n---\n", "---\nkey: value\n---\n"),
        ("---\nkey: value\n---\n\n  ", "---\nkey: value\n---\n\n"),
        ("---\nkey: value\n---", ""),
        ("---\nkey: value", ""),
        ("# Body\n---\nkey: value\n---\n", ""),
        (" ---\nkey: value\n---\nBody", ""),
        ("---\nkey: value\n...\nBody", ""),
        ("", ""),
    ])
    func hiddenPrefixMatchesTheWebBoundary(source: String, prefix: String) {
        #expect(Syntax.contentStart(in: source) == prefix.utf16.count)
    }
}
