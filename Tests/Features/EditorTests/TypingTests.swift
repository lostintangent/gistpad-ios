import Foundation
import Markdown
import Testing

@testable import Editor

struct TypingTests {
    @Test(arguments: ["- ", "* ", "1. ", "- [ ] ", "- [x]", "  - \t", "\t2) \t"])
    func returnOnAnEmptyItemExitsWithoutAnExtraBlankLine(_ source: String) throws {
        let edit = try #require(
            MarkdownDocument(source).edit(typing: "\n", over: NSRange(location: source.utf16.count, length: 0)))
        #expect(edit.result == "")
        #expect(edit.selection == NSRange(location: 0, length: 0))
    }

    @Test func anEmptyItemEndsTheListAndKeepsItsLineBreak() throws {
        let source = "1. First\r\n2. \r\nAfter"
        let range = (source as NSString).range(of: "2. ")
        let edit = try #require(
            MarkdownDocument(source).edit(typing: "\n", over: NSRange(location: NSMaxRange(range), length: 0)))
        #expect(edit.result == "1. First\r\n\r\nAfter")
    }

    @Test(arguments: ["Plain paragraph", "1.not a list", "-not a list", "999999999. item"])
    func ordinaryReturnFallsBackToUIKit(_ source: String) throws {
        #expect(
            MarkdownDocument(source).edit(typing: "\n", over: NSRange(location: source.utf16.count, length: 0)) == nil)
    }

    @Test(arguments: ["---\n- ", "```\n- "])
    func returnInAnUnfinishedLiteralTypesNatively(_ source: String) {
        #expect(
            MarkdownDocument(source).edit(typing: "\n", over: NSRange(location: source.utf16.count, length: 0)) == nil)
    }

    @Test func aURLPastedOverInlineCodeTypesNatively() {
        let source = "- Prose `code` after"
        let code = (source as NSString).range(of: "code")
        #expect(MarkdownDocument(source).edit(typing: "https://example.test", over: code) == nil)
    }

    @Test func pastedURLsEscapeMarkdownAndRetainTheSelectedLabel() throws {
        let source = "Before 日本語 [a]\\b after"
        let selection = (source as NSString).range(of: "日本語 [a]\\b")
        let edit = try #require(
            MarkdownDocument(source).edit(typing: "https://example.test/a_(b)?q=c", over: selection))
        let changed = edit.result
        #expect(changed == "Before [日本語 \\[a\\]\\\\b](<https://example.test/a_(b)?q=c>) after")
        #expect(
            edit.selection == NSRange(location: changed.utf16.count - " after".utf16.count, length: 0))
    }

    @Test(arguments: [
        "not a url", "javascript:alert(1)", "file:///private/note", "https://",
        "https://example.test\n", "https://example.test two", "mailto:user@example.test",
    ])
    func nonWebOrMultiItemPasteUsesNormalInput(_ replacement: String) throws {
        #expect(
            MarkdownDocument("Label").edit(typing: replacement, over: NSRange(location: 0, length: 5)) == nil)
    }

    @Test func URLPasteRequiresANonemptySingleLineSelection() throws {
        for (source, selection) in [
            ("Label", NSRange(location: 2, length: 0)),
            (" ", NSRange(location: 0, length: 1)),
            ("Two\nlines", NSRange(location: 0, length: 9)),
        ] {
            #expect(
                MarkdownDocument(source).edit(typing: "https://example.test", over: selection) == nil)
        }
    }

    /// Types `keys` one at a time from the end of `source`, using native insertion when
    /// the document declines, and returns the source with its caret marked by `|`.
    private func type(_ keys: String, after source: String = "") throws -> String {
        var text = source
        var caret = source.utf16.count
        for key in keys.map(String.init) {
            let selection = NSRange(location: caret, length: 0)
            if let edit = MarkdownDocument(text).edit(typing: key, over: selection) {
                text = edit.result
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
            #expect(MarkdownDocument("word").edit(typing: opener, over: start) == nil)
        }
    }

    @Test func aCloserTheLineNeedsIsTypedInsteadOfSteppedOver() throws {
        let source = "(see (x)"
        let selection = NSRange(location: 7, length: 0)
        #expect(MarkdownDocument(source).edit(typing: ")", over: selection) == nil)
        let mismatched = NSRange(location: 2, length: 0)
        #expect(MarkdownDocument("(x]").edit(typing: ")", over: mismatched) == nil)
    }

    @Test(arguments: ["()", "[]", "{}"])
    func backspaceInsideAnEmptyPairDeletesBoth(_ pair: String) throws {
        let source = "a \(pair) b"
        let edit = try #require(
            MarkdownDocument(source).edit(typing: "", over: NSRange(location: 2, length: 1)))
        #expect(edit.result == "a  b")
        #expect(edit.selection == NSRange(location: 2, length: 0))
        let filled = NSRange(location: 0, length: 1)
        #expect(MarkdownDocument("(x)").edit(typing: "", over: filled) == nil)
    }

    @Test(arguments: ["```\nf", "---\ntitle: "])
    func bracketsStayOutOfUnfinishedCodeAndFrontMatter(_ source: String) throws {
        let end = NSRange(location: source.utf16.count, length: 0)
        #expect(MarkdownDocument(source).edit(typing: "(", over: end) == nil)
    }

    @Test func bracketsStayOutOfInlineCode() throws {
        let source = "Use `f()` here"
        let inside = NSRange(location: (source as NSString).range(of: "()").location + 1, length: 0)
        #expect(MarkdownDocument(source).edit(typing: ")", over: inside) == nil)
        let opener = NSRange(location: inside.location - 1, length: 1)
        #expect(MarkdownDocument(source).edit(typing: "", over: opener) == nil)
    }
}
