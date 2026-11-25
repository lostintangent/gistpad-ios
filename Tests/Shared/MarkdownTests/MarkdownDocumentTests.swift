import Foundation
import Testing

@testable import Markdown

struct MarkdownDocumentTests {
    @Test func spansUseUTF16RangesWithoutChangingSource() throws {
        let source = "# 👨‍👩‍👧‍👦 日本語\nالعربية `code`\n- [ ] Duplicate\n- [ ] Duplicate\n"
        let before = Array(source.utf8)
        let spans = MarkdownDocument(source).spans
        #expect(!spans.isEmpty)
        for span in spans {
            #expect(Range(span.range, in: source) != nil)
        }
        #expect(Array(source.utf8) == before)
    }

    @Test func blocksKeepMarkdownBlocksAndMarkersOutOfProtectedContent() throws {
        let source = """
            ---
            title: Notebook
            ---
            ## 日本語 👩🏽‍💻
            First line
            second line

            - [x] Finished
              continued
            > - [ ] Quoted task
            | table |
            ```md
            ## Not a heading
            - [ ] Not a task
            ```
            Last `code` line
            """
        let document = MarkdownDocument(source)
        let blocks = document.blocks
        let text = source as NSString
        #expect(blocks.map(\.kind) == [
            .heading, .paragraph, .listItem, .paragraph, .tableRow, .code, .paragraph,
        ])
        #expect(blocks.map { text.substring(with: $0.range) } == [
            "## 日本語 👩🏽‍💻",
            "First line\nsecond line",
            "- [x] Finished\n  continued",
            "> - [ ] Quoted task",
            "| table |",
            "```md\n## Not a heading\n- [ ] Not a task\n```",
            "Last `code` line",
        ])
        #expect(blocks[0].level == 2)
        #expect(text.substring(with: try #require(blocks[2].marker)) == "- [x] ")
        #expect(text.substring(with: try #require(blocks[2].taskMarker)) == "[x]")
        #expect(document.taskMarkers == [try #require(blocks[2].taskMarker), text.range(of: "[ ]")])
    }

    @Test func headingsWithInlineCodeStillMarkTheirEntireLine() {
        let source = "## Install `tool`\n```md\n## Hidden\n```\n"
        let headings = MarkdownDocument(source).blocks.filter { $0.kind == .heading }
        #expect(headings.map(\.range) == [(source as NSString).range(of: "## Install `tool`")])
        #expect(headings.first?.level == 2)
    }

    @Test(arguments: [
        ("---\nkey: value\n---\n\n\n# Body", "---\nkey: value\n---\n\n\n"),
        (
            "--- \r\nkey: 日本語 👩🏽‍💻\r\n---\t\r\n \t\r\nBody",
            "--- \r\nkey: 日本語 👩🏽‍💻\r\n---\t\r\n \t\r\n"
        ),
        ("---\nkey: value\n---\n", "---\nkey: value\n---\n"),
        ("---\nkey: value\n---\n\n  ", "---\nkey: value\n---\n\n"),
        ("---\nkey: value\n---", ""),
        ("---\nkey: value", ""),
        ("# Body\n---\nkey: value\n---\n", ""),
        (" ---\nkey: value\n---\nBody", ""),
        ("---\nkey: value\n...\nBody", ""),
        ("", ""),
    ])
    func contentStartMatchesTheWebBoundary(source: String, prefix: String) {
        let document = MarkdownDocument(source)
        #expect(document.contentStart == prefix.utf16.count)
        #expect(document.body == (source as NSString).substring(from: prefix.utf16.count))
    }

    @Test func protectedRangesExcludeFrontMatterAndCodeOnlyInsideTheRange() {
        let source = "---\ntitle: test\n---\n日本語 `code`\n```swift\nlet x = 1\n```\n"
        let range = NSRange(location: 20, length: (source as NSString).length - 20)
        let ranges = MarkdownDocument(source).protectedRanges(in: range)
        #expect(!ranges.isEmpty)
        #expect(ranges.allSatisfy { NSIntersectionRange($0, range) == $0 })
        #expect(ranges.contains { (source as NSString).substring(with: $0).contains("let x") })
    }

    @Test(arguments: [
        (
            "Before\n````swift\n```\nlet value = 1\n```` not a closer\n~~~~\n`````\nAfter",
            ["````swift\n```\nlet value = 1\n```` not a closer\n~~~~\n`````\n"]
        ),
        (
            "Prose\n> ~~~~ js\n> `value`\n> ~~~~\n\n- ```swift\n  let value = 1",
            ["> ~~~~ js\n> `value`\n> ~~~~\n", "- ```swift\n  let value = 1"]
        ),
        ("```\n- ```\nStill protected\n```\nProse", ["```\n- ```\nStill protected\n```\n"]),
        // Only `---` closes front matter, so this one runs to the end.
        ("---\nkey: value\n...\nBody", ["---\nkey: value\n...\nBody"]),
    ])
    func literalsProtectUntilTheirClosingLine(source: String, protected: [String]) {
        let ranges = MarkdownDocument(source).protectedRanges(in: NSRange(location: 0, length: source.utf16.count))
        #expect(ranges.map { (source as NSString).substring(with: $0) } == protected)
    }

    @Test func protectedRangesMatchCodeSpansAcrossLinesAndEscapedOpeners() {
        let source = #"""
            日本語 👩🏽‍💻 ``a ` b`` and `two
            lines` then \`not code and \``still code` and `closed\`
            """#
        let ranges = MarkdownDocument(source).protectedRanges(in: NSRange(location: 0, length: source.utf16.count))
        #expect(
            ranges.map { (source as NSString).substring(with: $0) } == [
                "``a ` b``", "`two\nlines`", "`still code`", #"`closed\`"#,
            ])
        #expect(ranges.allSatisfy { Range($0, in: source) != nil })
    }

    @Test func unmatchedTicksDoNotHideProseOrCrossParagraphsAndProtectedBlocks() {
        for source in ["a ` lone delimiter", "`first\n\nsecond`", "`first\n~~~\ncode\n~~~\nlast`"] {
            let ranges = MarkdownDocument(source).protectedRanges(
                in: NSRange(location: 0, length: source.utf16.count))
            #expect(!ranges.contains { (source as NSString).substring(with: $0).contains("first") })
        }
    }

    @Test func frontMatterUsesExactUTF16BoundariesAndClipsInsideCode() {
        let source = "---\r\ntitle: 日本語 👨‍👩‍👧‍👦\r\n---\r\nProse `cafe\u{301}` after"
        let document = MarkdownDocument(source)
        let ranges = document.protectedRanges(in: NSRange(location: 0, length: source.utf16.count))
        #expect(
            ranges.map { (source as NSString).substring(with: $0) } == [
                "---\r\ntitle: 日本語 👨‍👩‍👧‍👦\r\n---\r\n", "`cafe\u{301}`",
            ])
        let partial = (source as NSString).range(of: "afe\u{301}")
        #expect(document.protectedRanges(in: partial) == [partial])
        #expect(document.protectedRanges(in: (source as NSString).range(of: "Prose")).isEmpty)
    }

    @Test func unfinishedFrontMatterIsProtectedConservatively() {
        let source = "---\ntitle: draft\nStill editing metadata"
        let whole = NSRange(location: 0, length: source.utf16.count)
        #expect(MarkdownDocument(source).protectedRanges(in: whole) == [whole])
    }

    @Test func spansKeepVisibleMarkdownDelimitersWithTheirElement() {
        let source = """
            ## A heading ##
            - [ ] Open task
            - [X] Completed task
            [Link label](https://example.com)
            [[Wiki note]]
            *emphasis* and **strong**
            """
        let strings = strings(of: source)
        #expect(strings(.heading) == ["## A heading ##"])
        #expect(strings(.punctuation) == ["-", "-"])
        #expect(strings(.task) == ["[ ]"])
        #expect(strings(.checkedTask) == ["[X]"])
        #expect(strings(.link) == ["[Link label](https://example.com)", "[[Wiki note]]"])
        #expect(strings(.linkDestination) == ["https://example.com"])
        #expect(strings(.strong) == ["**strong**"])
        #expect(strings(.emphasis) == ["*emphasis*"])
    }

    @Test func codeAndItsDelimitersPaintOverProseStyles() {
        let source = "`[literal](url) **not emphasis**`\n```swift\nlet value = 1\n```\n"
        let spans = MarkdownDocument(source).spans
        let literal = (source as NSString).range(of: "literal")
        #expect(spans.last { NSLocationInRange(literal.location, $0.range) }?.kind == .code)
        #expect(spans.last { NSLocationInRange(0, $0.range) }?.kind == .code)
        #expect(spans.filter { $0.kind == .code }.count == 2)
        #expect(strings(of: source)(.punctuation) == ["```swift\n", "```\n"])
    }

    @Test func spansRecognizeQuotesNestedEmphasisHTMLStrikesAndOrderedMarkers() {
        let source = """
            > Quoted _emphasis_ and **strong** with ***both***
            > 2) Quoted list item
            14. Numbered item
            - Ordinary bullet
            <span class="note">HTML</span> and ~~deleted~~
            """
        let strings = strings(of: source)
        #expect(
            strings(.blockquote) == [
                "> Quoted _emphasis_ and **strong** with ***both***", "> 2) Quoted list item",
            ])
        #expect(strings(.emphasis).contains("_emphasis_"))
        #expect(strings(.emphasis).contains("***both***"))
        #expect(strings(.strong).contains("**strong**"))
        #expect(strings(.strong).contains("***both***"))
        #expect(strings(.orderedMarker) == ["2)", "14."])
        #expect(strings(.punctuation) == ["-"])
        #expect(strings(.htmlTag) == [#"<span class="note">"#, "</span>"])
        #expect(strings(.strikethrough) == ["~~deleted~~"])
    }

    @Test func emphasisLeavesIntrawordUnderscoresAndEscapedMarkersLiteral() {
        let source = #"""
            keep__field__name and keep_field_name and keep___field___name
            \**literal**
            \_literal_
            __strong__ and ___both___
            """#
        let spans = MarkdownDocument(source).spans
        let plain = (source as NSString).range(
            of: "keep__field__name and keep_field_name and keep___field___name")
        #expect(!spans.contains { NSIntersectionRange($0.range, plain).length > 0 })
        #expect(!spans.contains { (source as NSString).substring(with: $0.range).contains("literal") })
        let strings = strings(of: source)
        #expect(strings(.strong).contains("__strong__"))
        #expect(strings(.emphasis).contains("___both___"))
    }

    private func strings(of source: String) -> (MarkdownDocument.Span.Kind) -> [String] {
        let spans = MarkdownDocument(source).spans
        return { kind in
            spans.filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
        }
    }
}
