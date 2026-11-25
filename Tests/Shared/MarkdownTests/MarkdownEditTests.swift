import Foundation
import Testing

@testable import Markdown

struct MarkdownEditTests {
    @Test func duplicateTasksTargetOnlyTheSpecifiedOccurrence() throws {
        let source = "👩🏽‍💻\n- [ ] Duplicate\n- [ ] Duplicate\n"
        let range = (source as NSString).range(of: "[ ]", options: .backwards)
        let mutation = MarkdownEdit(range: range, expected: "[ ]", replacement: "[x]")
        #expect(try mutation.applying(to: source) == "👩🏽‍💻\n- [ ] Duplicate\n- [x] Duplicate\n")
    }

    @Test func invalidOrStaleSourceIsRejected() {
        let source = "📝 - [ ] task"
        #expect(throws: MarkdownEdit.Failure.changed) {
            try MarkdownEdit(range: NSRange(location: 1, length: 1), expected: "", replacement: "x")
                .applying(to: source)
        }
        #expect(throws: MarkdownEdit.Failure.changed) {
            try MarkdownEdit(range: NSRange(location: 0, length: 2), expected: "[ ]", replacement: "[x]")
                .applying(to: source)
        }
    }

    @Test func canonicallyEquivalentButDifferentSourceIsNotAnExactMatch() {
        let source = "cafe\u{301}"
        #expect(throws: MarkdownEdit.Failure.changed) {
            try MarkdownEdit(
                range: NSRange(location: 0, length: source.utf16.count),
                expected: "caf\u{e9}", replacement: "coffee"
            ).applying(to: source)
        }
    }

    @Test func orderedReplacementsMapBothSelectionEdgesAtEveryBoundary() throws {
        let source = "before|a123bc|after"
        let boundaries = [0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 11, 11, 11, 11, 12, 13, 14, 15, 16, 17]
        for start in boundaries.indices {
            for end in start..<boundaries.count {
                let edit = MarkdownEdit(
                    range: NSRange(location: 7, length: 6), expected: "a123bc",
                    replacements: [
                        (NSRange(location: 7, length: 0), "# "),
                        (NSRange(location: 8, length: 3), "X"),
                        (NSRange(location: 11, length: 2), ""),
                    ], selection: NSRange(location: start, length: end - start))
                #expect(
                    edit.selection == NSRange(
                        location: boundaries[start], length: boundaries[end] - boundaries[start]))
                #expect(
                    try edit.applying(to: source).utf8.elementsEqual("before|# aX|after".utf8))
            }
        }
    }
}
