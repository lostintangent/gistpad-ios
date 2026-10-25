import Foundation
import GistPadComments
import Testing
@testable import GistPadPreview

struct PreviewCommentHighlightTests {
    private let document = PreviewDocument(
        text: "A native note", id: "comments-fixture", generation: .max)

    @Test func catalogKeepsLongNodesIntactAndUsesUTF16() throws {
        let text = "🫧 " + String(repeating: "native ", count: 4_000)
        let catalog = try PreviewCommentCatalog.decode([
            "version": 1, "documentID": document.id, "generation": String(document.generation),
            "segments": [text, "One separate node"]
        ], document: document)
        #expect(catalog.segments == [text, "One separate node"])
        #expect(catalog.segments[0].utf16.count == 28_003)
    }

    @Test func catalogRejectsWrongIdentityTypesAndVersions() {
        for value: [String: Any] in [
            ["version": true, "documentID": document.id, "generation": String(document.generation), "segments": []],
            ["version": 2, "documentID": document.id, "generation": String(document.generation), "segments": []],
            ["version": 1, "documentID": "other", "generation": String(document.generation), "segments": []],
            ["version": 1, "documentID": document.id, "generation": 1, "segments": []],
            ["version": 1, "documentID": document.id, "generation": String(document.generation), "segments": [1]]
        ] {
            #expect(throws: (any Error).self) {
                try PreviewCommentCatalog.decode(value, document: document)
            }
        }
    }

    @Test func activationResolvesEveryOverlapIDNativelyWithoutAJSNumberRoundTrip() throws {
        let configuration = CommentHighlightConfiguration(quotes: [
            CommentQuote(commentID: .max, quote: "native"),
            CommentQuote(commentID: 10, quote: "native")
        ])
        let highlights = CommentQuoteMatcher.highlights(
            quotes: configuration.quotes, segments: [document.text])
        let ids = try PreviewCommentActivation.decode(
            activation(start: 2, end: 8), document: document,
            highlights: highlights, configuration: configuration)
        #expect(ids == [.max, 10])
    }

    @Test func unknownStaleAndOversizedActivationsCannotOpenAThread() {
        let configuration = CommentHighlightConfiguration(quotes: [
            CommentQuote(commentID: 10, quote: "native")
        ])
        let highlights = CommentQuoteMatcher.highlights(
            quotes: configuration.quotes, segments: [document.text])
        for value: [String: Any] in [
            activation(start: 1, end: 8),
            activation(start: 2, end: 9),
            activation(start: 2, end: 8).merging(["generation": "0"]) { _, new in new },
            activation(start: 2, end: 8).merging(["segment": true]) { _, new in new },
            activation(start: 2, end: 8).merging(["extra": String(repeating: "x", count: 16_384)]) { _, new in new }
        ] {
            #expect(throws: (any Error).self) {
                try PreviewCommentActivation.decode(
                    value, document: document, highlights: highlights, configuration: configuration)
            }
        }
    }

    @Test func hiddenIdleHighlightsCannotActivateButAnExplicitSelectionCan() throws {
        var configuration = CommentHighlightConfiguration(
            quotes: [CommentQuote(commentID: 10, quote: "native")], showsInlineComments: false)
        let highlights = CommentQuoteMatcher.highlights(
            quotes: configuration.quotes, segments: [document.text])
        #expect(throws: (any Error).self) {
            try PreviewCommentActivation.decode(
                activation(start: 2, end: 8), document: document,
                highlights: highlights, configuration: configuration)
        }
        configuration.selectedCommentID = 10
        #expect(try PreviewCommentActivation.decode(
            activation(start: 2, end: 8), document: document,
            highlights: highlights, configuration: configuration) == [10])
    }

    @Test func commentSelectionPreservesExactWhitespaceLineEndingsAndUnicode() throws {
        let quote = "  cafe\u{0301} 🫧\r\n"
        let selection = try PreviewCommentSelection.decode([
            "version": 1, "documentID": document.id, "generation": String(document.generation),
            "quote": quote
        ], document: document)
        #expect(try #require(selection.quote).utf8.elementsEqual(quote.utf8))
        let empty = try PreviewCommentSelection.decode([
            "version": 1, "documentID": document.id, "generation": String(document.generation),
            "quote": NSNull()
        ], document: document)
        #expect(empty.quote == nil)
    }

    @Test func commentSelectionRejectsStaleIdentityAndInvalidShapes() {
        let snapshot: [String: Any] = [
            "version": 1, "documentID": document.id, "generation": String(document.generation),
            "quote": "native"
        ]
        for value: [String: Any] in [
            snapshot.merging(["version": true]) { _, new in new },
            snapshot.merging(["generation": "0"]) { _, new in new },
            snapshot.merging(["documentID": "other"]) { _, new in new },
            snapshot.merging(["quote": 42]) { _, new in new },
            snapshot.filter { $0.key != "quote" }
        ] {
            #expect(throws: (any Error).self) {
                try PreviewCommentSelection.decode(value, document: document)
            }
        }
    }

    private func activation(start: Int, end: Int) -> [String: Any] {
        [
            "version": 1, "type": "commentActivate", "documentID": document.id,
            "generation": String(document.generation), "segment": 0, "start": start, "end": end
        ]
    }
}
