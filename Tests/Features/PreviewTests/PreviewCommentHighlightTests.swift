import Foundation
import Testing
@testable import Preview

struct PreviewCommentHighlightTests {
    @Test func catalogKeepsLongNodesIntactAndUsesUTF16() throws {
        let text = "🫧 " + String(repeating: "native ", count: 4_000)
        let catalog: PreviewCommentCatalog = try PreviewBridge.decode([
            "documentID": "comments-fixture", "generation": 1, "segments": [text, "One separate node"]
        ])
        #expect(catalog.segments == [text, "One separate node"])
        #expect(catalog.segments[0].utf16.count == 28_003)
    }

    @Test func commentSelectionPreservesExactWhitespaceLineEndingsAndUnicode() throws {
        let quote = "  cafe\u{0301} 🫧\r\n"
        let selection: PreviewCommentSelection = try PreviewBridge.decode(["quote": quote])
        #expect(try #require(selection.quote).utf8.elementsEqual(quote.utf8))
        let empty: PreviewCommentSelection = try PreviewBridge.decode(["quote": NSNull()])
        #expect(empty.quote == nil)
    }
}
