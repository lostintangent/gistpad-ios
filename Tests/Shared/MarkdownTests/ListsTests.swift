import Foundation
import Testing

@testable import Markdown

@Suite struct ListsTests {
    @Test(arguments: [
        ("- First", "- First\n- "),
        ("* First", "* First\n* "),
        ("+ First", "+ First\n+ "),
        ("1. First", "1. First\n2. "),
        ("9. First", "9. First\n10. "),
        ("12) First", "12) First\n13) "),
        ("- [ ] First", "- [ ] First\n- [ ] "),
        ("- [x] Done", "- [x] Done\n- [ ] "),
        ("* [X] Done", "* [X] Done\n* [ ] "),
        ("  - Nested", "  - Nested\n  - "),
        ("\t* Nested", "\t* Nested\n\t* "),
        ("    3. Nested", "    3. Nested\n    4. "),
        ("-  Spaced", "-  Spaced\n-  "),
        ("1. [x] Done", "1. [x] Done\n2. [ ] "),
    ])
    func continuingKeepsTheExactListStyle(_ example: (String, String)) throws {
        let (source, expected) = example
        let edit = try #require(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: source.utf16.count, length: 0)))
        #expect(edit.result == expected)
        #expect(edit.selection == NSRange(location: expected.utf16.count, length: 0))
    }

    @Test func splittingAndReplacingInsideAnItemPreserveUnicodeAndTheSuffix() throws {
        let source = "- 日本語 👩🏽‍💻 after"
        let range = (source as NSString).range(of: "👩🏽‍💻 ")
        let edit = try #require(
            MarkdownDocument(source).edit(continuingListAt: range))
        let changed = edit.result
        #expect(changed == "- 日本語 \n- after")
        #expect(edit.selection == NSRange(location: "- 日本語 \n- ".utf16.count, length: 0))
    }

    @Test func continuingPreservesCRLFAndRenumbersFollowingSiblings() throws {
        let source = "8. First\r\n9. Next\r\n"
        let edit = try #require(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: 8, length: 0)))
        #expect(edit.result == "8. First\r\n9. \r\n10. Next\r\n")
    }

    @Test func continuingPutsTextAfterTheNewItemsMarker() throws {
        let source = "1. [x] Done\n2. Next"
        let end = NSRange(location: (source as NSString).range(of: "\n").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(continuingListAt: end, with: "Added"))
        #expect(edit.result == "1. [x] Done\n2. [ ] Added\n3. Next")
        #expect(edit.selection == NSRange(location: "1. [x] Done\n2. [ ] Added".utf16.count, length: 0))
    }

    @Test func continuingNeedsAnUnquotedItemAndASelectionInItsText() {
        #expect(MarkdownDocument("> - Quoted").edit(continuingListAt: NSRange(location: 10, length: 0)) == nil)
        #expect(MarkdownDocument("- Item").edit(continuingListAt: NSRange(location: 1, length: 0)) == nil)
    }

    @Test func renumberingKeepsNestedItemsAndStopsBeforeADifferentList() throws {
        let source = "1. First\n2. Second\n   1. Nested\n3. Third\n- Other\n1. Independent"
        let edit = try #require(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: 8, length: 0)))
        #expect(
            edit.result
                == "1. First\n2. \n3. Second\n   1. Nested\n4. Third\n- Other\n1. Independent")
        #expect(edit.selection == NSRange(location: "1. First\n2. ".utf16.count, length: 0))
    }

    @Test func renumberingContinuesPastInlineCode() throws {
        let source = "1. First\n2. Run `make`\n3. Last"
        let edit = try #require(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: 8, length: 0)))
        #expect(edit.result == "1. First\n2. \n3. Run `make`\n4. Last")
    }

    @Test func renumberingStopsAtProtectedContentAndAnIndependentParagraph() throws {
        for tail in [
            "\nParagraph\n1. Independent",
            "\n```markdown\n2. Code\n```\n3. Independent",
            "\n\n2. Independent",
        ] {
            let source = "1. First" + tail
            let edit = try #require(
                MarkdownDocument(source).edit(continuingListAt: NSRange(location: 8, length: 0)))
            #expect(edit.result == "1. First\n2. " + tail)
        }
    }

    @Test func oneMutationRenumbersTheEntireRemainingListWithoutMovingTheNewCaret() throws {
        let source = (1...200).map { "\($0). Item 👩🏽‍💻" }.joined(separator: "\n")
        let insertion = (source as NSString).range(of: "\n").location
        let edit = try #require(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: insertion, length: 0)))
        let result = edit.result
        #expect(result.hasPrefix("1. Item 👩🏽‍💻\n2. \n3. Item 👩🏽‍💻"))
        #expect(result.hasSuffix("201. Item 👩🏽‍💻"))
        #expect(edit.selection == NSRange(location: insertion + "\n2. ".utf16.count, length: 0))
    }

    @Test func aSelectionAcrossLinesDoesNotContinueAList() throws {
        let source = "- First\n- Second"
        #expect(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: 3, length: 7)) == nil)
    }

    @Test(arguments: [
        "---\n- metadata", "---\n- metadata\n",
        "```\n- code", "```\n- code\n",
        "~~~~\n- code\n~~~", "- ```\n  - code",
        "````\n```\n- code", "> ~~~\n> - code",
    ])
    func unfinishedLiteralsNeverContinueOrIndent(_ source: String) throws {
        #expect(
            MarkdownDocument(source).edit(continuingListAt: NSRange(location: source.utf16.count, length: 0)) == nil)
        #expect(
            MarkdownDocument(source).edit(indenting: NSRange(location: 0, length: source.utf16.count))
                == nil)
    }

    @Test func closedBlocksPermitFollowingLists() throws {
        for source in ["---\ntitle: test\n---\n- prose", "```\n- code\n```\n- prose"] {
            let range = NSRange(location: source.utf16.count, length: 0)
            #expect(MarkdownDocument(source).edit(continuingListAt: range) != nil)
        }
    }

    @Test func indentingRefusesASelectionThatCrossesIntoCode() {
        let source = "- Prose `code` after\n```\n- protected\n```\n"
        let crossing = NSRange(location: 0, length: source.utf16.count)
        #expect(MarkdownDocument(source).edit(indenting: crossing) == nil)
    }

    @Test func indentNestsOrderedItemsAtTheParentsContentColumn() throws {
        let source = "1. a\n2. b"
        let selection = NSRange(location: (source as NSString).range(of: "2. b").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(indenting: selection))
        #expect(edit.result == "1. a\n   1. b")
    }

    @Test func indentNestsUnderTwoDigitNumbersAtFourSpaces() throws {
        let source = "10. a\n11. b"
        let selection = NSRange(location: (source as NSString).range(of: "11. b").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(indenting: selection))
        #expect(edit.result == "10. a\n    1. b")
    }

    @Test func indentRenumbersTheListItLeaves() throws {
        let source = "1. a\n2. b\n3. c"
        let selection = NSRange(location: (source as NSString).range(of: "2. b").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(indenting: selection))
        #expect(edit.result == "1. a\n   1. b\n2. c")
    }

    @Test func outdentRenumbersBothLists() throws {
        let source = "1. a\n   1. b\n2. c"
        let selection = NSRange(location: (source as NSString).range(of: "1. b").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(outdenting: selection))
        #expect(edit.result == "1. a\n2. b\n3. c")
    }

    @Test func indentNestsBulletsAtTwoSpaces() throws {
        let source = "- a\n- b"
        let selection = NSRange(location: (source as NSString).range(of: "- b").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(indenting: selection))
        #expect(edit.result == "- a\n  - b")
    }

    @Test func indentKeepsRelativeStructureInAMultilineSelection() throws {
        let source = "1. a\n2. b\n3. c\n4. d"
        let start = (source as NSString).range(of: "2. b").location
        let end = NSMaxRange((source as NSString).range(of: "3. c"))
        let edit = try #require(
            MarkdownDocument(source).edit(indenting: NSRange(location: start, length: end - start)))
        #expect(edit.result == "1. a\n   1. b\n   2. c\n2. d")
    }

    @Test func indentTakesNestedChildrenAlong() throws {
        let source = "1. a\n2. b\n   1. nested\n3. c"
        let selection = NSRange(location: (source as NSString).range(of: "2. b").location, length: 0)
        let edit = try #require(MarkdownDocument(source).edit(indenting: selection))
        #expect(edit.result == "1. a\n   1. b\n      1. nested\n2. c")
    }

    @Test func indentOutdentPreserveTheLogicalUTF16SelectionAndLineEndings() throws {
        let source = "- 日本語\r\n  - 👩🏽‍💻\r\nAfter"
        let selection = NSRange(location: 2, length: "- 日本語\r\n  - 👩🏽‍💻".utf16.count - 2)
        let edit = try #require(
            MarkdownDocument(source).edit(indenting: selection))
        let changed = edit.result
        #expect(changed == "  - 日本語\r\n    - 👩🏽‍💻\r\nAfter")
        #expect(edit.selection?.location == selection.location + 2)
        #expect(edit.selection?.length == selection.length + 2)
        let undo = try #require(
            MarkdownDocument(changed).edit(outdenting: edit.selection!))
        #expect(undo.result == source)
        #expect(undo.selection == selection)
    }

    @Test func indentExcludesAnUntouchedLineAtTheSelectionEnd() throws {
        let source = "First\nSecond\nThird"
        let selection = NSRange(location: 0, length: "First\nSecond\n".utf16.count)
        let edit = try #require(
            MarkdownDocument(source).edit(indenting: selection))
        #expect(edit.result == "  First\n  Second\nThird")
        #expect(NSMaxRange(edit.selection!) == "  First\n  Second\n".utf16.count)
    }

    @Test func tabsPartialIndentEmptyTextAndUnindentedOutdentAreExplicit() throws {
        for (source, expected) in [("\t- Item", "\t\t- Item"), ("", "  ")] {
            let edit = try #require(
                MarkdownDocument(source).edit(indenting: NSRange(location: source.utf16.count, length: 0)))
            #expect(edit.result == expected)
        }
        for (source, expected) in [
            ("\t- Item", "- Item"), (" - Item", "- Item"), ("   - Item", " - Item"),
        ] {
            let edit = try #require(
                MarkdownDocument(source).edit(outdenting: NSRange(location: source.utf16.count, length: 0)))
            #expect(edit.result == expected)
        }
        #expect(
            MarkdownDocument("Plain").edit(outdenting: NSRange(location: 2, length: 0)) == nil)
    }
}
