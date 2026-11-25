import Foundation
import Markdown
import Testing
@testable import Preview

@Suite("Preview messages")
struct PreviewMessageTests {
    private let document = MarkdownDocument("👩🏽‍💻\r\n- [ ] Same\r\n- [x] Same\r\n```\r\n- [ ] code\r\n```\r\n")

    /// A message from the page's seventh render, which is the one it shows.
    private func message(_ body: [String: Any], allowsTaskEdits: Bool = true) throws -> PreviewMessage? {
        try PreviewMessage(
            body.merging(["generation": 7]) { sent, _ in sent },
            file: PreviewFile(document: document, allowsTaskEdits: allowsTaskEdits), generation: 7)
    }

    @Test("A task toggle names a box by its UTF-16 location, and the document makes the edit")
    func taskToggles() throws {
        let checked = (document.text as NSString).range(of: "[x]").location
        guard case .taskToggle(let edit)? = try message(["type": "taskToggle", "location": checked]) else {
            Issue.record("Expected the document's edit")
            return
        }
        #expect(edit.result == "👩🏽‍💻\r\n- [ ] Same\r\n- [ ] Same\r\n```\r\n- [ ] code\r\n```\r\n")

        let code = (document.text as NSString).range(of: "[ ] code").location
        for location in [-1, 0, checked + 1, code, Int.max] {
            #expect(throws: PreviewError.self) { try message(["type": "taskToggle", "location": location]) }
        }
        #expect(throws: PreviewError.self) { try message(["type": "taskToggle"]) }
        #expect(throws: PreviewError.self) {
            try message(["type": "taskToggle", "location": checked], allowsTaskEdits: false)
        }
        #expect(try message(["type": "taskToggle", "generation": 6, "location": checked]) == nil)
    }

    @Test("Only approved external URL schemes are accepted")
    func links() throws {
        func link(_ target: String) throws -> PreviewMessage? {
            try message(["type": "link", "kind": "external", "target": target])
        }
        for target in ["javascript:alert(1)", "file:///private/a", "https://user:secret@example.com", "data:text/html,hello", ""] {
            #expect(throws: PreviewError.self) { try link(target) }
        }
        guard case .openURL(let url)? = try link("https://example.com") else {
            Issue.record("Expected a URL to open")
            return
        }
        #expect(url.absoluteString == "https://example.com")
    }

    @Test("A tapped highlight arrives as its segment and range")
    func commentActivation() throws {
        let tap: [String: Any] = ["type": "commentActivate", "segment": 2, "start": 4, "end": 9]
        #expect(throws: PreviewError.self) { try message(tap.filter { $0.key != "end" }) }
        guard case .commentActivate(segment: 2, start: 4, end: 9)? = try message(tap) else {
            Issue.record("Expected the tapped highlight")
            return
        }
    }
}
