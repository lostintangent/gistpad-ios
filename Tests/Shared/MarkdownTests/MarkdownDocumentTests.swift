import Foundation
import Testing

@testable import Markdown

struct MarkdownDocumentTests {
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
        #expect(text.substring(with: try #require(blocks[2].prefix)) == "- [x] ")
        #expect(text.substring(with: try #require(blocks[2].box)) == "[x]")
        #expect(document.tasks.compactMap(\.box) == [try #require(blocks[2].box), text.range(of: "[ ]")])
    }

    @Test(arguments: [
        ("# Title", "Title"), ("  ##   Spaced   ##  ", "Spaced"), ("### a # b ###", "a # b"),
        ("# a#", "a#"), ("## ##", ""), ("#", ""),
    ])
    func aHeadingsTitleDropsItsHashesAndSpaces(_ example: (String, String)) throws {
        let document = MarkdownDocument(example.0)
        let title = try #require(document.blocks.first?.title)
        #expect((example.0 as NSString).substring(with: title) == example.1)
    }

    @Test func sectionsSplitBeforeEachHeading() {
        let source = "---\ntitle: x\n---\nIntro\n\n# One\nText\n\n## Two\n- item\n"
        let sections = MarkdownDocument(source).sections
        #expect(sections.map(\.heading?.level) == [nil, 1, 2])
        #expect(sections.map { (source as NSString).substring(with: $0.range) } == [
            "Intro", "# One\nText", "## Two\n- item",
        ])
        #expect(MarkdownDocument("# Only").sections.map(\.heading?.kind) == [.heading])
    }

    @Test func appendingAddsAParagraphOrOneTaskPerLine() {
        let paragraph = MarkdownDocument("# Today\n\nA thought").edit(appendingParagraph: "A second thought\n")
        #expect(paragraph.result == "# Today\n\nA thought\n\nA second thought\n")
        let tasks = MarkdownDocument(paragraph.result).edit(appendingTasks: "First task\n  \t\n日本語 👩🏽‍💻\n")
        #expect(tasks.result == paragraph.result + "- [ ] First task\n- [ ] 日本語 👩🏽‍💻\n")
        #expect(MarkdownDocument("").edit(appendingTasks: "Task").result == "- [ ] Task\n")
        #expect(MarkdownDocument("A\r\n").edit(appendingParagraph: "B").result == "A\r\n\r\nB\r\n")
        #expect(MarkdownDocument("- [ ] A\r\n").edit(appendingTasks: "B").result == "- [ ] A\r\n- [ ] B\r\n")
    }

    @Test func appendingLinesTrimsTheTextAndKeepsACarriageReturnNotesBreak() {
        #expect(MarkdownDocument("A").edit(appendingLines: "\nB\nC\n\n").result == "A\nB\nC\n")
        #expect(MarkdownDocument("A\n").edit(appendingLines: "B").result == "A\nB\n")
        #expect(MarkdownDocument("A\r").edit(appendingLines: "B").result == "A\rB\r")
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
    func literalsRunUntilTheirClosingLine(source: String, literals: [String]) {
        let ranges = MarkdownDocument(source).literals.map(\.range)
        #expect(ranges.map { (source as NSString).substring(with: $0) } == literals)
    }

    @Test func inlineCodeSpansLinesAndRespectsEscapedOpeners() {
        let source = #"""
            日本語 👩🏽‍💻 ``a ` b`` and `two
            lines` then \`not code and \``still code` and `closed\`
            """#
        let document = MarkdownDocument(source)
        let ranges = document.proseRuns.flatMap { document.inlineCode(in: $0) }
        #expect(
            ranges.map { (source as NSString).substring(with: $0) } == [
                "``a ` b``", "`two\nlines`", "`still code`", #"`closed\`"#,
            ])
        #expect(ranges.allSatisfy { Range($0, in: source) != nil })
    }

    @Test func unmatchedTicksDoNotProtectProseOrCrossParagraphsAndLiterals() {
        for source in ["a ` lone delimiter", "`first\n\nsecond`", "`first\n~~~\ncode\n~~~\nlast`"] {
            let prose = (source as NSString).range(of: source.hasPrefix("a") ? "lone" : "first")
            #expect(!MarkdownDocument(source).isProtected(prose))
        }
    }

    @Test func unfinishedFrontMatterIsLiteralToTheEnd() {
        let source = "---\ntitle: draft\nStill editing metadata"
        let document = MarkdownDocument(source)
        #expect(document.literals.map(\.range) == [document.range])
        #expect(document.contentStart == 0)
    }
}
