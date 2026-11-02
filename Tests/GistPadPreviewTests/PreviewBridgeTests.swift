import Foundation
import Testing
@testable import GistPadPreview

@Suite("Preview bridge")
struct PreviewBridgeTests {
    private let text = "👩🏽‍💻\r\n- [ ] Same\r\n- [x] Same\r\n"

    private func file(allowsTaskEdits: Bool = true) -> PreviewFile {
        PreviewFile(text: text, id: "fixture", generation: 7, allowsTaskEdits: allowsTaskEdits)
    }

    private func toggle(at location: Int, expected: String, replacement: String) -> [String: Any] {
        [
            "type": "taskToggle", "documentID": "fixture", "generation": 7,
            "edit": ["location": location, "length": 3, "expectedMarker": expected, "replacementMarker": replacement]
        ]
    }

    @Test("Task toggles flip one UTF-16 marker range, and untrusted ranges are rejected")
    func taskToggles() throws {
        let range = (text as NSString).range(of: "[x]")
        let message = try PreviewBridge.decode(toggle(at: range.location, expected: "[x]", replacement: "[ ]"), file: file())
        guard case .event(.taskToggle(let edit)) = message else {
            Issue.record("Expected a task edit")
            return
        }
        #expect(edit.range == range)
        #expect((text as NSString).replacingCharacters(in: range, with: edit.replacementMarker)
            == "👩🏽‍💻\r\n- [ ] Same\r\n- [ ] Same\r\n")

        let unchecked = (text as NSString).range(of: "[ ]").location
        for location in [-1, 0, Int.max - 1, Int.max, unchecked] {
            #expect(throws: PreviewFailure.self) {
                try PreviewBridge.decode(toggle(at: location, expected: "[ ]", replacement: "bad"), file: file())
            }
        }
        #expect(try PreviewBridge.decode(
            toggle(at: range.location, expected: "[x]", replacement: "[ ]"), file: file(allowsTaskEdits: false)) == nil)
    }

    @Test("Only approved external URL schemes are accepted")
    func links() throws {
        func link(_ target: String) -> [String: Any] {
            ["type": "link", "documentID": "fixture", "generation": 7, "kind": "external", "target": target]
        }
        for target in ["javascript:alert(1)", "file:///private/a", "https://user:secret@example.com", "data:text/html,hello", ""] {
            #expect(throws: PreviewFailure.self) { try PreviewBridge.decode(link(target), file: file()) }
        }
        #expect(try PreviewBridge.decode(link("https://example.com"), file: file()) != nil)
    }
}
