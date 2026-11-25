import Foundation
import Testing

@testable import Markdown

struct MarkdownEditTests {
    @Test func duplicateTasksTargetOnlyTheSpecifiedOccurrence() throws {
        let source = "👩🏽‍💻\n- [ ] Duplicate\n- [ ] Duplicate\n"
        let range = (source as NSString).range(of: "[ ]", options: .backwards)
        let edit = try #require(MarkdownDocument(source).edit(togglingTaskAt: range.location))
        #expect(edit.result == "👩🏽‍💻\n- [ ] Duplicate\n- [x] Duplicate\n")
    }

    @Test func documentsAreEqualOnlyCodeUnitForCodeUnit() {
        #expect(MarkdownDocument("- [ ] task") == MarkdownDocument("- [ ] task"))
        #expect(MarkdownDocument("- [ ] task") != MarkdownDocument("- [x] task"))
        // Swift's String equality is canonical, so these would match there.
        #expect(MarkdownDocument("cafe\u{301}") != MarkdownDocument("caf\u{e9}"))
    }

    @Test func orderedReplacementsMapBothSelectionEdgesAtEveryBoundary() throws {
        let document = MarkdownDocument("before|a123bc|after")
        let boundaries = [0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 11, 11, 11, 11, 12, 13, 14, 15, 16, 17]
        for start in boundaries.indices {
            for end in start..<boundaries.count {
                let edit = MarkdownEdit(
                    document: document, range: NSRange(location: 7, length: 6),
                    replacements: [
                        (NSRange(location: 7, length: 0), "# "),
                        (NSRange(location: 8, length: 3), "X"),
                        (NSRange(location: 11, length: 2), ""),
                    ], selection: NSRange(location: start, length: end - start))
                #expect(
                    edit.selection == NSRange(
                        location: boundaries[start], length: boundaries[end] - boundaries[start]))
                #expect(edit.result.utf8.elementsEqual("before|# aX|after".utf8))
            }
        }
    }
}
