import Foundation
import Testing
@testable import Preview

@Suite("Preview bridge")
struct PreviewBridgeTests {
    private let text = "👩🏽‍💻\r\n- [ ] Same\r\n- [x] Same\r\n"

    private func file(allowsTaskEdits: Bool = true) -> PreviewFile {
        PreviewFile(text: text, id: "fixture", generation: 7, allowsTaskEdits: allowsTaskEdits)
    }

    private func toggle(at location: Int, expected: String, replacement: String) -> [String: Any] {
        [
            "type": "taskToggle", "fileID": "fixture", "generation": 7,
            "edit": ["location": location, "length": 3, "expectedMarker": expected, "replacementMarker": replacement]
        ]
    }

    @Test("Task toggles flip one UTF-16 marker range, and untrusted ranges are rejected")
    func taskToggles() throws {
        let range = (text as NSString).range(of: "[x]")
        let message = try PreviewBridge.decode(toggle(at: range.location, expected: "[x]", replacement: "[ ]"), file: file())
        guard case .event(.taskToggle(let edited, _, let replacement, let generation)) = message else {
            Issue.record("Expected a task edit")
            return
        }
        #expect(edited == range)
        #expect(generation == 7)
        #expect((text as NSString).replacingCharacters(in: range, with: replacement)
            == "👩🏽‍💻\r\n- [ ] Same\r\n- [ ] Same\r\n")

        let unchecked = (text as NSString).range(of: "[ ]").location
        for location in [-1, 0, Int.max - 1, Int.max, unchecked] {
            #expect(throws: PreviewError.self) {
                try PreviewBridge.decode(toggle(at: location, expected: "[ ]", replacement: "bad"), file: file())
            }
        }
        #expect(try PreviewBridge.decode(
            toggle(at: range.location, expected: "[x]", replacement: "[ ]"), file: file(allowsTaskEdits: false)) == nil)
    }

    @Test("Only approved external URL schemes are accepted")
    func links() throws {
        func link(_ target: String) -> [String: Any] {
            ["type": "link", "fileID": "fixture", "generation": 7, "kind": "external", "target": target]
        }
        for target in ["javascript:alert(1)", "file:///private/a", "https://user:secret@example.com", "data:text/html,hello", ""] {
            #expect(throws: PreviewError.self) { try PreviewBridge.decode(link(target), file: file()) }
        }
        #expect(try PreviewBridge.decode(link("https://example.com"), file: file())
            == .event(.openURL(URL(string: "https://example.com")!)))
    }

    @Test("A tapped highlight arrives as its segment and range")
    func commentActivation() throws {
        let tap: [String: Any] = [
            "type": "commentActivate", "fileID": "fixture", "generation": 7, "segment": 2, "start": 4, "end": 9
        ]
        #expect(try PreviewBridge.decode(tap, file: file()) == .commentActivate(segment: 2, start: 4, end: 9))
        #expect(throws: PreviewError.self) { try PreviewBridge.decode(tap.filter { $0.key != "end" }, file: file()) }
    }
}
