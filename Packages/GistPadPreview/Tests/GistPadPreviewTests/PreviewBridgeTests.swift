import Foundation
import Testing
@testable import GistPadPreview

@Suite("Preview bridge")
struct PreviewBridgeTests {
    private let text = "👩🏽‍💻\r\n- [ ] Same\r\n- [x] Same\r\n"
    private var document: PreviewDocument { PreviewDocument(text: text, id: "fixture", generation: UInt64.max) }

    @Test("Duplicate labels use a UTF-16 source range")
    func duplicateTask() throws {
        let range = (text as NSString).range(of: "[x]")
        let edit = TaskToggleEdit(documentID: "fixture", generation: UInt64.max, range: range,
                                  expectedMarker: "[x]", replacementMarker: "[ ]")
        try edit.validate(in: text, documentID: "fixture", generation: UInt64.max)
        let result = (text as NSString).replacingCharacters(in: range, with: edit.replacementMarker)
        #expect(result == "👩🏽‍💻\r\n- [ ] Same\r\n- [ ] Same\r\n")
    }

    @Test("Stale generations and changed markers are rejected")
    func staleTask() {
        let edit = TaskToggleEdit(documentID: "fixture", generation: 1,
                                  range: NSRange(location: 0, length: 3),
                                  expectedMarker: "[ ]", replacementMarker: "[x]")
        #expect(throws: PreviewFailure.staleDocument) {
            try edit.validate(in: text, documentID: "fixture", generation: 2)
        }
        #expect(throws: PreviewFailure.invalidTaskEdit) {
            try edit.validate(in: text, documentID: "fixture", generation: 1)
        }
    }

    @Test("Untrusted task edits cannot overflow or change arbitrary text")
    func invalidTaskRanges() {
        for location in [-1, Int.max, 0] {
            let edit = TaskToggleEdit(documentID: "fixture", generation: 1,
                                      range: NSRange(location: location, length: 3),
                                      expectedMarker: "[ ]", replacementMarker: "bad")
            #expect(throws: PreviewFailure.invalidTaskEdit) {
                try edit.validate(in: text, documentID: "fixture", generation: 1)
            }
        }
    }

    @Test("The wire format preserves UInt64 generations")
    func decodeTask() throws {
        let range = (text as NSString).range(of: "[x]")
        let body: [String: Any] = [
            "version": 1, "type": "taskToggle", "documentID": "fixture",
            "generation": String(UInt64.max),
            "edit": ["location": range.location, "length": 3,
                     "expectedMarker": "[x]", "replacementMarker": "[ ]"]
        ]
        guard case .event(.taskToggle(let edit)) = try PreviewBridge.decode(body, document: document) else {
            Issue.record("Expected a validated task edit")
            return
        }
        #expect(edit.generation == UInt64.max)
        #expect(edit.range == range)
    }

    @Test("Only approved external URL schemes are accepted")
    func links() {
        for target in ["javascript:alert(1)", "file:///private/a", "https://user:password@example.com", "data:text/html,hello"] {
            let body: [String: Any] = [
                "version": 1, "type": "link", "documentID": "fixture",
                "generation": String(UInt64.max), "kind": "external", "target": target
            ]
            #expect(throws: PreviewFailure.invalidMessage) {
                try PreviewBridge.decode(body, document: document)
            }
        }
    }

    @Test("Malformed, oversized and unknown messages are rejected")
    func malformedMessages() {
        for body: [String: Any] in [
            ["version": 2, "type": "ready"],
            ["version": 1, "type": "unknown", "documentID": "fixture", "generation": String(UInt64.max)],
            ["version": 1, "type": "failure", "message": String(repeating: "x", count: 20_000)],
            ["version": 1, "type": "height", "documentID": "fixture", "generation": String(UInt64.max), "height": -1]
        ] {
            #expect(throws: PreviewFailure.invalidMessage) {
                try PreviewBridge.decode(body, document: document)
            }
        }
    }

    @Test("Synthetic fixture is bundled")
    func fixture() throws {
        #expect(try PreviewFixtures.allSyntax.contains("Duplicate task"))
    }
}
