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

    @Test func anExcerptIsTheProseOnOneLineWithoutHeadingsTasksTablesOrCode() {
        let source = """
            ---
            title: Hidden
            ---
            # Groceries
            Buy these
            before Friday.
            - milk
            - [ ] eggs
            1. [x] bread
            | aisle | 4 |
            ```sh
            # not a heading
            ```
            * butter
              and jam
            """
        #expect(MarkdownDocument(source).excerpt == "Buy these before Friday. milk butter and jam")
        #expect(MarkdownDocument("# Only a heading\n- [ ] A task\n").excerpt == nil)
        #expect(MarkdownDocument(String(repeating: "word ", count: 50)).excerpt?.count == 160)
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

    @Test func codeAndItsDelimitersOverrideProseSpans() {
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

    @Test func aKeystrokeChangesOnlyItsParagraphsSpans() {
        let paragraph = "Some **bold** prose.\n\n"
        let length = paragraph.utf16.count
        let old = MarkdownDocument(String(repeating: paragraph, count: 100))
        let typed = NSRange(location: 50 * length + 5, length: 1)
        let new = MarkdownDocument(
            (old.text as NSString).replacingCharacters(in: NSRange(location: typed.location, length: 0), with: "x"))
        #expect(new.spanRange(for: typed, from: old) == NSRange(location: 50 * length, length: length))
    }

    @Test func spanningWhatAnEditTouchedSpansTheNoteAsSpanningItAllWould() throws {
        let note = """
            ---
            title: Note
            ---

            # Heading
            Prose with `code
            across` lines and **bold** and [a link](https://example.com).

            ```swift
            let a = 1

            ```
            - [ ] Task
            > quote `tick`
            ~~~
            tilde
            ~~~
            Tail with ``double `ticks``.
            """
        let pieces = [
            "```", "~~~", "`", "``", "\n", "\n\n", "---", "---\n", "# ", "> ", "- [ ] ", "1. ", "**", "_", "x", " ",
        ]
        var random = SplitMix64(seed: 411)
        var document = MarkdownDocument(note)
        for _ in 0..<3_000 {
            let source = document.text as NSString
            let location = Int.random(in: 0...source.length, using: &random)
            let change = NSRange(
                location: location, length: min(Int.random(in: 0...3, using: &random), source.length - location))
            let typed = (0..<Int.random(in: 0...2, using: &random)).map { _ in pieces.randomElement(using: &random)! }
                .joined()
            // Pasting a note over itself replaces every character, even the ones that come back the same.
            let (replaced, replacement) =
                Int.random(in: 0..<50, using: &random) == 0
                ? (document.range, source.replacingCharacters(in: change, with: typed)) : (change, typed)
            let next = MarkdownDocument(source.replacingCharacters(in: replaced, with: replacement))
            let edited = NSRange(location: replaced.location, length: replacement.utf16.count)
            let spanned = next.spanRange(for: edited, from: document)
            let spans = next.spans(in: spanned)
            var patched = kinds(document.spans, length: source.length)
            patched.replaceSubrange(Range(replaced)!, with: repeatElement(nil, count: edited.length))
            patched.replaceSubrange(Range(spanned)!, with: kinds(spans, length: next.range.length)[Range(spanned)!])
            try #require(
                spans.allSatisfy { NSUnionRange($0.range, spanned) == spanned }
                    && patched == kinds(next.spans, length: next.range.length),
                "\(document.text.debugDescription) became \(next.text.debugDescription)")
            document = next.range.length > 1_500 ? MarkdownDocument(note) : next
        }
    }

    /// Each code unit's span kinds in order. Nil is text no span has reached.
    private func kinds(_ spans: [MarkdownDocument.Span], length: Int) -> [[MarkdownDocument.Span.Kind]?] {
        var kinds = [[MarkdownDocument.Span.Kind]?](repeating: [], count: length)
        for span in spans {
            for offset in Range(span.range)! { kinds[offset]?.append(span.kind) }
        }
        return kinds
    }

    private func strings(of source: String) -> (MarkdownDocument.Span.Kind) -> [String] {
        let spans = MarkdownDocument(source).spans
        return { kind in
            spans.filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
        }
    }
}

/// A seeded generator, so a failing sequence of edits replays the same way.
private struct SplitMix64: RandomNumberGenerator {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
