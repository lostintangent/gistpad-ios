import Foundation
import Testing

@testable import Editor

@Suite struct TypingTests {
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
    ])
    func returnContinuesTheExactListStyle(_ example: (String, String)) throws {
        let (source, expected) = example
        let edit = try #require(
            try Typing.edit(
                in: source, selection: NSRange(location: source.utf16.count, length: 0),
                replacement: "\n"))
        #expect(try edit.applying(to: source) == expected)
        #expect(edit.selection == NSRange(location: expected.utf16.count, length: 0))
    }

    @Test(arguments: ["- ", "* ", "1. ", "- [ ] ", "- [x]", "  - \t", "\t2) \t"])
    func returnOnAnEmptyItemExitsWithoutAnExtraBlankLine(_ source: String) throws {
        let edit = try #require(
            try Typing.edit(
                in: source, selection: NSRange(location: source.utf16.count, length: 0),
                replacement: "\n"))
        #expect(try edit.applying(to: source) == "")
        #expect(edit.selection == NSRange(location: 0, length: 0))
    }

    @Test func splittingAndReplacingInsideAnItemPreserveUnicodeAndTheSuffix() throws {
        let source = "- 日本語 👩🏽‍💻 after"
        let range = (source as NSString).range(of: "👩🏽‍💻 ")
        let edit = try #require(
            try Typing.edit(
                in: source, selection: range, replacement: "\n"))
        let changed = try edit.applying(to: source)
        #expect(changed == "- 日本語 \n- after")
        #expect(edit.selection == NSRange(location: "- 日本語 \n- ".utf16.count, length: 0))
    }

    @Test func returnPreservesCRLFAndRenumbersFollowingSiblings() throws {
        let source = "8. First\r\n9. Next\r\n"
        let edit = try #require(
            try Typing.edit(
                in: source, selection: NSRange(location: 8, length: 0),
                replacement: "\n"))
        #expect(try edit.applying(to: source) == "8. First\r\n9. \r\n10. Next\r\n")
        let empty = "1. First\r\n2. \r\nAfter"
        let range = (empty as NSString).range(of: "2. ")
        let exit = try #require(
            try Typing.edit(
                in: empty, selection: NSRange(location: NSMaxRange(range), length: 0),
                replacement: "\n"))
        #expect(try exit.applying(to: empty) == "1. First\r\n\r\nAfter")
    }

    @Test(arguments: ["Plain paragraph", "1.not a list", "-not a list", "999999999. item"])
    func ordinaryReturnFallsBackToUIKit(_ source: String) throws {
        #expect(
            try Typing.edit(
                in: source, selection: NSRange(location: source.utf16.count, length: 0),
                replacement: "\n") == nil)
    }

    @Test func rangeValidationRejectsOverflowAndSplitSurrogates() {
        for range in [
            NSRange(location: -1, length: 0), NSRange(location: Int.max, length: 1),
            NSRange(location: 0, length: Int.max), NSRange(location: 3, length: 0),
        ] {
            #expect(throws: Edit.Failure.changed) {
                try Typing.edit(in: "- 👩", selection: range, replacement: "\n")
            }

            #expect(throws: Edit.Failure.changed) {
                try Typing.indent(in: "- 👩", selection: range, outdent: false)
            }
        }
    }

    @Test func renumberingKeepsNestedItemsAndStopsBeforeADifferentList() throws {
        let source = "1. First\n2. Second\n   1. Nested\n3. Third\n- Other\n1. Independent"
        let edit = try #require(
            try Typing.edit(
                in: source, selection: NSRange(location: 8, length: 0), replacement: "\n"))
        #expect(
            try edit.applying(to: source)
                == "1. First\n2. \n3. Second\n   1. Nested\n4. Third\n- Other\n1. Independent")
        #expect(edit.selection == NSRange(location: "1. First\n2. ".utf16.count, length: 0))
    }

    @Test func renumberingStopsAtProtectedContentAndAnIndependentParagraph() throws {
        for tail in [
            "\nParagraph\n1. Independent",
            "\n```markdown\n2. Code\n```\n3. Independent",
            "\n\n2. Independent",
        ] {
            let source = "1. First" + tail
            let edit = try #require(
                try Typing.edit(
                    in: source, selection: NSRange(location: 8, length: 0),
                    replacement: "\n"))
            #expect(try edit.applying(to: source) == "1. First\n2. " + tail)
        }
    }

    @Test func oneMutationRenumbersTheEntireRemainingListWithoutMovingTheNewCaret() throws {
        let source = (1...200).map { "\($0). Item 👩🏽‍💻" }.joined(separator: "\n")
        let insertion = (source as NSString).range(of: "\n").location
        let edit = try #require(
            try Typing.edit(
                in: source, selection: NSRange(location: insertion, length: 0),
                replacement: "\n"))
        let result = try edit.applying(to: source)
        #expect(result.hasPrefix("1. Item 👩🏽‍💻\n2. \n3. Item 👩🏽‍💻"))
        #expect(result.hasSuffix("201. Item 👩🏽‍💻"))
        #expect(edit.selection == NSRange(location: insertion + "\n2. ".utf16.count, length: 0))
        #expect(throws: Edit.Failure.changed) {
            try edit.applying(to: source.replacingOccurrences(of: "200.", with: "201."))
        }
    }

    @Test func selectionAcrossLinesUsesOrdinaryReturnInsteadOfGuessingAList() throws {
        let source = "- First\n- Second"
        #expect(
            try Typing.edit(
                in: source, selection: NSRange(location: 3, length: 7),
                replacement: "\n") == nil)
    }

    @Test(arguments: [
        "---\n- metadata", "---\n- metadata\n",
        "```\n- code", "```\n- code\n",
        "~~~~\n- code\n~~~", "- ```\n  - code",
        "````\n```\n- code", "> ~~~\n> - code",
    ])
    func unfinishedProtectedBlocksNeverReceiveSmartEdits(_ source: String) throws {
        #expect(
            try Typing.edit(
                in: source, selection: NSRange(location: source.utf16.count, length: 0),
                replacement: "\n") == nil)
        #expect(
            try Typing.indent(
                in: source, selection: NSRange(location: 0, length: source.utf16.count), outdent: false)
                == nil)
    }

    @Test func closedBlocksPermitFollowingLists() throws {
        for source in ["---\ntitle: test\n---\n- prose", "```\n- code\n```\n- prose"] {
            let range = NSRange(location: source.utf16.count, length: 0)
            #expect(try Typing.edit(in: source, selection: range, replacement: "\n") != nil)
        }
    }

    @Test func protectedRangesIncludeInlineCodeAndCrossBoundarySelections() throws {
        let source = "- Prose `code` after\n```\n- protected\n```\n"
        let code = (source as NSString).range(of: "code")
        #expect(
            try Typing.edit(
                in: source, selection: code, replacement: "https://example.test") == nil
        )
        let crossing = NSRange(location: 0, length: source.utf16.count)
        #expect(try Typing.indent(in: source, selection: crossing, outdent: false) == nil)
    }

    @Test func indentNestsOrderedItemsAtTheParentsContentColumn() throws {
        let source = "1. a\n2. b"
        let selection = NSRange(location: (source as NSString).range(of: "2. b").location, length: 0)
        let edit = try #require(try Typing.indent(in: source, selection: selection, outdent: false))
        #expect(try edit.applying(to: source) == "1. a\n   1. b")
    }

    @Test func indentNestsUnderTwoDigitNumbersAtFourSpaces() throws {
        let source = "10. a\n11. b"
        let selection = NSRange(location: (source as NSString).range(of: "11. b").location, length: 0)
        let edit = try #require(try Typing.indent(in: source, selection: selection, outdent: false))
        #expect(try edit.applying(to: source) == "10. a\n    1. b")
    }

    @Test func indentRenumbersTheListItLeaves() throws {
        let source = "1. a\n2. b\n3. c"
        let selection = NSRange(location: (source as NSString).range(of: "2. b").location, length: 0)
        let edit = try #require(try Typing.indent(in: source, selection: selection, outdent: false))
        #expect(try edit.applying(to: source) == "1. a\n   1. b\n2. c")
    }

    @Test func outdentRenumbersBothLists() throws {
        let source = "1. a\n   1. b\n2. c"
        let selection = NSRange(location: (source as NSString).range(of: "1. b").location, length: 0)
        let edit = try #require(try Typing.indent(in: source, selection: selection, outdent: true))
        #expect(try edit.applying(to: source) == "1. a\n2. b\n3. c")
    }

    @Test func indentNestsBulletsAtTwoSpaces() throws {
        let source = "- a\n- b"
        let selection = NSRange(location: (source as NSString).range(of: "- b").location, length: 0)
        let edit = try #require(try Typing.indent(in: source, selection: selection, outdent: false))
        #expect(try edit.applying(to: source) == "- a\n  - b")
    }

    @Test func indentKeepsRelativeStructureInAMultilineSelection() throws {
        let source = "1. a\n2. b\n3. c\n4. d"
        let start = (source as NSString).range(of: "2. b").location
        let end = NSMaxRange((source as NSString).range(of: "3. c"))
        let edit = try #require(
            try Typing.indent(
                in: source, selection: NSRange(location: start, length: end - start), outdent: false))
        #expect(try edit.applying(to: source) == "1. a\n   1. b\n   2. c\n2. d")
    }

    @Test func indentTakesNestedChildrenAlong() throws {
        let source = "1. a\n2. b\n   1. nested\n3. c"
        let selection = NSRange(location: (source as NSString).range(of: "2. b").location, length: 0)
        let edit = try #require(try Typing.indent(in: source, selection: selection, outdent: false))
        #expect(try edit.applying(to: source) == "1. a\n   1. b\n      1. nested\n2. c")
    }

    @Test func indentOutdentPreserveTheLogicalUTF16SelectionAndLineEndings() throws {
        let source = "- 日本語\r\n  - 👩🏽‍💻\r\nAfter"
        let selection = NSRange(location: 2, length: "- 日本語\r\n  - 👩🏽‍💻".utf16.count - 2)
        let edit = try #require(
            try Typing.indent(in: source, selection: selection, outdent: false))
        let changed = try edit.applying(to: source)
        #expect(changed == "  - 日本語\r\n    - 👩🏽‍💻\r\nAfter")
        #expect(edit.selection?.location == selection.location + 2)
        #expect(edit.selection?.length == selection.length + 2)
        let undo = try #require(
            try Typing.indent(in: changed, selection: edit.selection!, outdent: true))
        #expect(try undo.applying(to: changed) == source)
        #expect(undo.selection == selection)
    }

    @Test func indentExcludesAnUntouchedLineAtTheSelectionEnd() throws {
        let source = "First\nSecond\nThird"
        let selection = NSRange(location: 0, length: "First\nSecond\n".utf16.count)
        let edit = try #require(
            try Typing.indent(in: source, selection: selection, outdent: false))
        #expect(try edit.applying(to: source) == "  First\n  Second\nThird")
        #expect(NSMaxRange(edit.selection!) == "  First\n  Second\n".utf16.count)
    }

    @Test func tabsPartialIndentEmptyTextAndUnindentedOutdentAreExplicit() throws {
        for (source, expected) in [("\t- Item", "\t\t- Item"), ("", "  ")] {
            let edit = try #require(
                try Typing.indent(
                    in: source, selection: NSRange(location: source.utf16.count, length: 0), outdent: false))
            #expect(try edit.applying(to: source) == expected)
        }
        for (source, expected) in [
            ("\t- Item", "- Item"), (" - Item", "- Item"), ("   - Item", " - Item"),
        ] {
            let edit = try #require(
                try Typing.indent(
                    in: source, selection: NSRange(location: source.utf16.count, length: 0), outdent: true))
            #expect(try edit.applying(to: source) == expected)
        }
        #expect(
            try Typing.indent(
                in: "Plain", selection: NSRange(location: 2, length: 0), outdent: true) == nil)
    }

    @Test func pastedURLsEscapeMarkdownAndRetainTheSelectedLabel() throws {
        let source = "Before 日本語 [a]\\b after"
        let selection = (source as NSString).range(of: "日本語 [a]\\b")
        let edit = try #require(
            try Typing.edit(
                in: source, selection: selection, replacement: "https://example.test/a_(b)?q=c"))
        let changed = try edit.applying(to: source)
        #expect(changed == "Before [日本語 \\[a\\]\\\\b](https://example.test/a_%28b%29?q=c) after")
        #expect(
            edit.selection == NSRange(location: changed.utf16.count - " after".utf16.count, length: 0))
    }

    @Test(arguments: [
        "not a url", "javascript:alert(1)", "file:///private/note", "https://",
        "https://example.test\n", "https://example.test two", "mailto:user@example.test",
    ])
    func nonWebOrMultiItemPasteUsesNormalInput(_ replacement: String) throws {
        #expect(
            try Typing.edit(
                in: "Label", selection: NSRange(location: 0, length: 5),
                replacement: replacement) == nil)
    }

    @Test func URLPasteRequiresANonemptySingleLineSelection() throws {
        for (source, selection) in [
            ("Label", NSRange(location: 2, length: 0)),
            (" ", NSRange(location: 0, length: 1)),
            ("Two\nlines", NSRange(location: 0, length: 9)),
        ] {
            #expect(
                try Typing.edit(
                    in: source, selection: selection, replacement: "https://example.test") == nil)
        }
    }

    /// Types `keys` one at a time from the end of `source`, using native insertion when
    /// `Typing.edit` declines, and returns the source with its caret marked by `|`.
    private func type(_ keys: String, after source: String = "") throws -> String {
        var text = source
        var caret = source.utf16.count
        for key in keys.map(String.init) {
            let selection = NSRange(location: caret, length: 0)
            if let edit = try Typing.edit(in: text, selection: selection, replacement: key) {
                text = try edit.applying(to: text)
                caret = try #require(edit.selection).location
            } else {
                text = (text as NSString).replacingCharacters(in: selection, with: key)
                caret += key.utf16.count
            }
        }
        return (text as NSString).replacingCharacters(
            in: NSRange(location: caret, length: 0), with: "|")
    }

    @Test func bracketsCloseAndStepOverThroughTasksLinksAndAsides() throws {
        let line = "- [ ] Read (vol 3) and [link](url) {x}"
        #expect(try type(line) == line + "|")
        #expect(try type("(") == "(|)")
        #expect(try type("[", after: "Berserk ") == "Berserk [|]")
        #expect(try type("((a))") == "((a))|")
        #expect(try type("{", after: "end.") == "end.{|}")
    }

    @Test func anOpenerBeforeAWordStaysSingle() throws {
        for opener in ["(", "[", "{"] {
            let start = NSRange(location: 0, length: 0)
            #expect(try Typing.edit(in: "word", selection: start, replacement: opener) == nil)
        }
    }

    @Test func aCloserTheLineNeedsIsTypedInsteadOfSteppedOver() throws {
        let source = "(see (x)"
        let selection = NSRange(location: 7, length: 0)
        #expect(try Typing.edit(in: source, selection: selection, replacement: ")") == nil)
        let mismatched = NSRange(location: 2, length: 0)
        #expect(try Typing.edit(in: "(x]", selection: mismatched, replacement: ")") == nil)
    }

    @Test(arguments: ["()", "[]", "{}"])
    func backspaceInsideAnEmptyPairDeletesBoth(_ pair: String) throws {
        let source = "a \(pair) b"
        let edit = try #require(
            try Typing.edit(in: source, selection: NSRange(location: 2, length: 1), replacement: ""))
        #expect(try edit.applying(to: source) == "a  b")
        #expect(edit.selection == NSRange(location: 2, length: 0))
        let filled = NSRange(location: 0, length: 1)
        #expect(try Typing.edit(in: "(x)", selection: filled, replacement: "") == nil)
    }

    @Test(arguments: ["```\nf", "---\ntitle: "])
    func bracketsStayOutOfUnfinishedCodeAndFrontMatter(_ source: String) throws {
        let end = NSRange(location: source.utf16.count, length: 0)
        #expect(try Typing.edit(in: source, selection: end, replacement: "(") == nil)
    }

    @Test func bracketsStayOutOfInlineCode() throws {
        let source = "Use `f()` here"
        let inside = NSRange(location: (source as NSString).range(of: "()").location + 1, length: 0)
        #expect(try Typing.edit(in: source, selection: inside, replacement: ")") == nil)
        let opener = NSRange(location: inside.location - 1, length: 1)
        #expect(try Typing.edit(in: source, selection: opener, replacement: "") == nil)
    }
}
