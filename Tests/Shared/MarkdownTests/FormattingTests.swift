import Foundation
import Testing

@testable import Markdown

struct FormattingTests {
    @Test func inlineFormattingKeepsUnicodeSelectedAndToggles() throws {
        let source = "日本語 👩🏽‍💻 cafe\u{301}"
        let selection = (source as NSString).range(of: "👩🏽‍💻")
        let edit = MarkdownDocument(source).edit(bolding: selection)
        let result = edit.result
        #expect(result == "日本語 **👩🏽‍💻** cafe\u{301}")
        #expect((result as NSString).substring(with: edit.selection!) == "👩🏽‍💻")
        let undo = MarkdownDocument(result).edit(bolding: edit.selection!)
        #expect(undo.result.utf8.elementsEqual(source.utf8))
    }

    @Test func italicDoesNotRemoveHalfOfBoldSyntax() throws {
        for selection in [NSRange(location: 0, length: 8), NSRange(location: 2, length: 4)] {
            let edit = MarkdownDocument("**note**").edit(italicizing: selection)
            #expect(edit.result == "***note***")
        }
    }

    @Test func emptyCaretFormattingLeavesAnInsertionPointBetweenMarkers() throws {
        let edit = MarkdownDocument("abc").edit(bolding: NSRange(location: 1, length: 0))
        #expect(edit.result == "a****bc")
        #expect(edit.selection == NSRange(location: 3, length: 0))
    }

    @Test func selectedLineBoundaryDoesNotIncludeTheFollowingLine() throws {
        let source = "First\nSecond\nThird"
        let edit = try #require(
            MarkdownDocument(source).edit(heading: 2, over: NSRange(location: 0, length: 6)))
        #expect(edit.result == "## First\nSecond\nThird")
        #expect(edit.selection == NSRange(location: 3, length: 6))
    }

    @Test func headingBodyRemovesClosingSyntaxButPreservesLiteralHashes() throws {
        let source = "## Heading ##\r\n## C#\r\n"
        let edit = try #require(
            MarkdownDocument(source).edit(heading: 0, over: NSRange(location: 0, length: source.utf16.count)))
        #expect(edit.result == "Heading\r\nC#\r\n")
        #expect(edit.selection == NSRange(location: 0, length: 13))
        #expect(
            MarkdownDocument("Body").edit(heading: 0, over: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func mixedChecklistsPreserveCheckedStateAndIndentation() throws {
        let source = "  - [X] Done\r\n\t9. Next\r\nPlain"
        let edit = try #require(
            MarkdownDocument(source).edit(checklisting: NSRange(location: 0, length: source.utf16.count)))
        let result = edit.result
        #expect(result == "  - [x] Done\r\n\t- [ ] Next\r\n- [ ] Plain")
        #expect(Range(edit.selection!, in: result) != nil)
        let toggle = try #require(
            MarkdownDocument(result).edit(checklisting: NSRange(location: 0, length: result.utf16.count)))
        #expect(toggle.result == "  Done\r\n\tNext\r\nPlain")
    }

    @Test func numberedListConversionUsesOneMutationAndMapsTheCaret() throws {
        let source = "- One\n* Two"
        let selection = NSRange(location: 0, length: source.utf16.count)
        let edit = try #require(
            MarkdownDocument(source).edit(numbering: selection))
        #expect(edit.result == "1. One\n2. Two")
        #expect(edit.selection == NSRange(location: 0, length: 13))
        let caret = try #require(
            MarkdownDocument("  note").edit(bulleting: NSRange(location: 4, length: 0)))
        #expect(caret.selection == NSRange(location: 6, length: 0))
    }

    @Test func inlineCodeUsesSafeDelimitersAndCanBeRemoved() throws {
        let source = "a ` b"
        let edit = MarkdownDocument(source).edit(coding: NSRange(location: 0, length: source.utf16.count))
        let result = edit.result
        #expect(result == "``a ` b``")
        let toggle = MarkdownDocument(result).edit(coding: edit.selection!)
        #expect(toggle.result == source)
        let padded = MarkdownDocument("`hello").edit(coding: NSRange(location: 0, length: 6))
        #expect(padded.result == "`` `hello ``")
        let paddedSource = padded.result
        let unpadded = MarkdownDocument(paddedSource).edit(coding: padded.selection!)
        #expect(unpadded.result == "`hello")
    }

    @Test func fencedCodeRetainsCRLFAndCannotCloseEarly() throws {
        let source = "a\r\n```\r\nb\r\n"
        let edit = MarkdownDocument(source).edit(fencing: NSRange(location: 0, length: source.utf16.count))
        #expect(edit.result == "````\r\na\r\n```\r\nb\r\n````\r\n")
        #expect(edit.selection == NSRange(location: 6, length: source.utf16.count))
    }

    @Test func linkEscapesLabelsAndParenthesizedDestinations() throws {
        let edit = try MarkdownDocument("note").edit(
            linking: NSRange(location: 0, length: 4), to: "https://example.com/a(b)", label: "A [draft]")
        #expect(edit.result == "[A \\[draft\\]](<https://example.com/a(b)>)")
    }

    @Test func linkRejectsUnsafeOrIncompleteDestinations() {
        for destination in [
            "", "example.com", "javascript:alert(1)", "https://", "mailto:", "tel:",
            "https://a.test/\nnext",
        ] {
            #expect(throws: MarkdownEdit.Failure.invalidLink) {
                try MarkdownDocument("note").edit(
                    linking: NSRange(location: 0, length: 4), to: destination, label: "note")
            }
        }
    }

    @Test func aBareTaskIsATaskToTheToolbar() throws {
        let source = "- [ ]"
        let whole = NSRange(location: 0, length: 5)
        let checklist = try #require(MarkdownDocument(source).edit(checklisting: whole))
        #expect(checklist.result == "")
        let bullet = try #require(MarkdownDocument(source).edit(bulleting: whole))
        #expect(bullet.result == "- ")
        let number = try #require(MarkdownDocument(source).edit(numbering: whole))
        #expect(number.result == "1. ")
    }

    @Test(arguments: [
        ("- [ ] Open", "- [x] Open"),
        ("- [X] Done", "- [ ] Done"),
        ("> - [ ] Quoted", "> - [x] Quoted"),
        ("3. [x] Numbered", "3. [ ] Numbered"),
    ])
    func togglingATaskFlipsOnlyItsBox(_ source: String, _ expected: String) throws {
        let box = (source as NSString).range(of: "[")
        let edit = try #require(MarkdownDocument(source).edit(togglingTaskAt: box.location))
        #expect(edit.result == expected)
        #expect(edit.selection == nil)
    }

    @Test func togglingATaskNeedsItsBoxOutsideCode() {
        #expect(MarkdownDocument("- [ ] Open").edit(togglingTaskAt: 3) == nil)
        #expect(MarkdownDocument("Plain [ ] text").edit(togglingTaskAt: 6) == nil)
        #expect(MarkdownDocument("```\n- [ ] Code\n```\n").edit(togglingTaskAt: 6) == nil)
    }
}
