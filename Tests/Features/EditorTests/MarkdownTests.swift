import Foundation
import Testing

@testable import Editor

@Test func highlightingUsesUTF16RangesWithoutChangingSource() throws {
  let source = "# 👨‍👩‍👧‍👦 日本語\nالعربية `code`\n- [ ] Duplicate\n- [ ] Duplicate\n"
  let before = Array(source.utf8)
  let spans = Syntax.spans(in: source)
  #expect(!spans.isEmpty)
  for span in spans {
    #expect(Range(span.range, in: source) != nil)
  }
  #expect(Array(source.utf8) == before)
}

@Test func duplicateTasksTargetOnlyTheSpecifiedOccurrence() throws {
  let source = "👩🏽‍💻\n- [ ] Duplicate\n- [ ] Duplicate\n"
  let range = (source as NSString).range(of: "[ ]", options: .backwards)
  let mutation = Edit(range: range, expected: "[ ]", replacement: "[x]")
  #expect(try mutation.applying(to: source) == "👩🏽‍💻\n- [ ] Duplicate\n- [x] Duplicate\n")
}

@Test func outlineKeepsMarkdownBlocksAndMarkersOutOfProtectedContent() throws {
  let source = """
    ---
    title: Notebook
    ---
    ## 日本語 👩🏽‍💻
    First line
    second line

    - [x] Finished
      continued
    | table |
    ```md
    ## Not a heading
    - [ ] Not a task
    ```
    Last `code` line
    """
  let outline = Syntax.outline(in: source)
  let text = source as NSString
  #expect(outline.blocks.map(\.kind) == [
    .heading, .paragraph, .listItem, .tableRow, .code, .paragraph,
  ])
  #expect(outline.blocks.map { text.substring(with: $0.range) } == [
    "## 日本語 👩🏽‍💻",
    "First line\nsecond line",
    "- [x] Finished\n  continued",
    "| table |",
    "```md\n## Not a heading\n- [ ] Not a task\n```",
    "Last `code` line",
  ])
  #expect(outline.blocks[0].level == 2)
  #expect(text.substring(with: try #require(outline.blocks[2].marker)) == "- [x] ")
  #expect(text.substring(with: try #require(outline.blocks[2].taskMarker)) == "[x]")
  #expect(outline.headings == [outline.blocks[0].range])
  #expect(outline.taskMarkers == [try #require(outline.blocks[2].taskMarker)])
  #expect(outline.frontMatterRanges.map { text.substring(with: $0) } == [
    "---\ntitle: Notebook\n---\n",
  ])
  #expect(outline.codeRanges.map { text.substring(with: $0) } == [
    "```md\n## Not a heading\n- [ ] Not a task\n```\n", "`code`",
  ])
}

@Test func headingsWithInlineCodeStillMarkTheirEntireLine() {
  let source = "## Install `tool`\n```md\n## Hidden\n```\n"
  let outline = Syntax.outline(in: source)
  let heading = (source as NSString).range(of: "## Install `tool`")
  #expect(outline.headings == [heading])
  #expect(outline.blocks.first?.kind == .heading)
  #expect(outline.blocks.first?.range == heading)
  #expect(outline.blocks.first?.level == 2)
}

@Test func invalidOrStaleSourceIsRejected() {
  let source = "📝 - [ ] task"
  #expect(throws: Edit.MutationError.invalidRange) {
    try Edit(range: NSRange(location: 1, length: 1), expected: "", replacement: "x")
      .applying(to: source)
  }
  #expect(throws: Edit.MutationError.sourceChanged) {
    try Edit(range: NSRange(location: 0, length: 2), expected: "[ ]", replacement: "[x]")
      .applying(to: source)
  }
}

@Test func canonicallyEquivalentButDifferentSourceIsNotAnExactMatch() {
  let source = "cafe\u{301}"
  #expect(throws: Edit.MutationError.sourceChanged) {
    try Edit(
      range: NSRange(location: 0, length: source.utf16.count),
      expected: "caf\u{e9}", replacement: "coffee"
    ).applying(to: source)
  }
}

@Test func writingToolsExcludesFrontmatterAndCodeOnlyInsideBoundary() {
  let source = "---\ntitle: test\n---\n日本語 `code`\n```swift\nlet x = 1\n```\n"
  let boundary = NSRange(location: 20, length: (source as NSString).length - 20)
  let ranges = Syntax.ignoredWritingToolsRanges(in: source, enclosing: boundary)
  #expect(!ranges.isEmpty)
  #expect(ranges.allSatisfy { NSIntersectionRange($0, boundary) == $0 })
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
])
func writingToolsProtectsFencesUntilTheirActualClosingDelimiter(source: String, protected: [String]) {
  let ranges = Syntax.ignoredWritingToolsRanges(
    in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
  #expect(ranges.map { (source as NSString).substring(with: $0) } == protected)
}

@Test func writingToolsProtectsMatchingCodeSpansAcrossLinesAndEscapedOpeners() {
  let source = #"""
    日本語 👩🏽‍💻 ``a ` b`` and `two
    lines` then \`not code and \``still code` and `closed\`
    """#
  let ranges = Syntax.ignoredWritingToolsRanges(
    in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
  #expect(
    ranges.map { (source as NSString).substring(with: $0) } == [
      "``a ` b``", "`two\nlines`", "`still code`", #"`closed\`"#,
    ])
  #expect(ranges.allSatisfy { Range($0, in: source) != nil })
}

@Test func unmatchedTicksDoNotHideProseOrCrossParagraphsAndProtectedBlocks() {
  for source in ["a ` lone delimiter", "`first\n\nsecond`", "`first\n~~~\ncode\n~~~\nlast`"] {
    let ranges = Syntax.ignoredWritingToolsRanges(
      in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
    #expect(!ranges.contains { (source as NSString).substring(with: $0).contains("first") })
  }
}

@Test func writingToolsFrontmatterUsesExactUTF16BoundariesAndClipsInsideCode() {
  let source = "---\r\ntitle: 日本語 👨‍👩‍👧‍👦\r\n...\r\nProse `cafe\u{301}` after"
  let full = NSRange(location: 0, length: source.utf16.count)
  let ranges = Syntax.ignoredWritingToolsRanges(in: source, enclosing: full)
  #expect(
    ranges.map { (source as NSString).substring(with: $0) } == [
      "---\r\ntitle: 日本語 👨‍👩‍👧‍👦\r\n...\r\n", "`cafe\u{301}`",
    ])
  let partial = (source as NSString).range(of: "afe\u{301}")
  #expect(Syntax.ignoredWritingToolsRanges(in: source, enclosing: partial) == [partial])
  let prose = (source as NSString).range(of: "Prose")
  #expect(Syntax.ignoredWritingToolsRanges(in: source, enclosing: prose).isEmpty)
}

@Test func unfinishedFrontmatterIsProtectedConservatively() {
  let source = "---\ntitle: draft\nStill editing metadata"
  let full = NSRange(location: 0, length: source.utf16.count)
  #expect(Syntax.ignoredWritingToolsRanges(in: source, enclosing: full) == [full])
}

@Test func syntaxThemeKeepsVisibleMarkdownDelimitersWithTheirElement() {
  let source = """
    ## A heading ##
    - [ ] Open task
    - [X] Completed task
    [Link label](https://example.com)
    [[Wiki note]]
    *emphasis* and **strong**
    """
  let spans = Syntax.spans(in: source)
  func strings(_ kind: Syntax.Kind) -> [String] {
    spans.filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
  }
  #expect(strings(.heading) == ["## A heading ##"])
  #expect(strings(.punctuation) == ["-", "-"])
  #expect(strings(.task) == ["[ ]"])
  #expect(strings(.checkedTask) == ["[X]"])
  #expect(strings(.link) == ["[Link label](https://example.com)", "[[Wiki note]]"])
  #expect(strings(.linkDestination) == ["https://example.com"])
  #expect(strings(.strong) == ["**strong**"])
  #expect(strings(.emphasis) == ["*emphasis*"])
}

@Test func codeContentAndItsDelimitersOverrideProseStylesTogether() {
  let source = "`[literal](url) **not emphasis**`\n```swift\nlet value = 1\n```\n"
  let spans = Syntax.spans(in: source)
  let literal = (source as NSString).range(of: "literal")
  #expect(spans.last { NSLocationInRange(literal.location, $0.range) }?.kind == .code)
  let tick = NSRange(location: 0, length: 1)
  #expect(spans.last { NSLocationInRange(tick.location, $0.range) }?.kind == .code)
  #expect(spans.filter { $0.kind == .code }.count == 4)
  #expect(
    spans.filter { $0.kind == .punctuation }.map { (source as NSString).substring(with: $0.range) }
      == ["```swift\n", "```\n"])
}

@Test func syntaxThemeRecognizesQuotesNestedEmphasisHTMLStrikesAndOrderedMarkers() {
  let source = """
    > Quoted _emphasis_ and **strong** with ***both***
    > 2) Quoted list item
    14. Numbered item
    - Ordinary bullet
    <span class="note">HTML</span> and ~~deleted~~
    """
  let spans = Syntax.spans(in: source)
  func strings(_ kind: Syntax.Kind) -> [String] {
    spans.filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
  }
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
  #expect(spans.allSatisfy { Range($0.range, in: source) != nil })
}

@Test func sourceEmphasisLeavesIntrawordUnderscoresAndEscapedMarkersLiteral() {
  let source = #"""
    keep__field__name and keep_field_name and keep___field___name
    \**literal**
    \_literal_
    __strong__ and ___both___
    """#
  let spans = Syntax.spans(in: source)
  let plain = (source as NSString).range(
    of: "keep__field__name and keep_field_name and keep___field___name")
  #expect(!spans.contains { NSIntersectionRange($0.range, plain).length > 0 })
  #expect(!spans.contains { (source as NSString).substring(with: $0.range).contains("literal") })
  #expect(
    spans.contains {
      $0.kind == .strong && (source as NSString).substring(with: $0.range) == "__strong__"
    })
  #expect(
    spans.contains {
      $0.kind == .emphasis && (source as NSString).substring(with: $0.range) == "___both___"
    })
}
