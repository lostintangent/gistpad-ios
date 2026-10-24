import Foundation
import Testing

@testable import GistPadEditor

@Test func highlightingUsesUTF16RangesWithoutChangingSource() throws {
  let source = "# 👨‍👩‍👧‍👦 日本語\nالعربية `code`\n- [ ] Duplicate\n- [ ] Duplicate\n"
  let before = Array(source.utf8)
  let spans = MarkdownSyntax.spans(in: source)
  #expect(!spans.isEmpty)
  for span in spans {
    #expect(Range(span.range, in: source) != nil)
  }
  #expect(Array(source.utf8) == before)
}

@Test func duplicateTasksTargetOnlyTheSpecifiedOccurrence() throws {
  let source = "👩🏽‍💻\n- [ ] Duplicate\n- [ ] Duplicate\n"
  let range = (source as NSString).range(of: "[ ]", options: .backwards)
  let mutation = SourceMutation(range: range, expected: "[ ]", replacement: "[x]")
  #expect(try mutation.applying(to: source) == "👩🏽‍💻\n- [ ] Duplicate\n- [x] Duplicate\n")
}

@Test func invalidOrStaleSourceIsRejected() {
  let source = "📝 - [ ] task"
  #expect(throws: SourceMutation.MutationError.invalidRange) {
    try SourceMutation(range: NSRange(location: 1, length: 1), expected: "", replacement: "x")
      .applying(to: source)
  }
  #expect(throws: SourceMutation.MutationError.sourceChanged) {
    try SourceMutation(range: NSRange(location: 0, length: 2), expected: "[ ]", replacement: "[x]")
      .applying(to: source)
  }
}

@Test func canonicallyEquivalentButDifferentSourceIsNotAnExactMatch() {
  let source = "cafe\u{301}"
  #expect(throws: SourceMutation.MutationError.sourceChanged) {
    try SourceMutation(
      range: NSRange(location: 0, length: source.utf16.count),
      expected: "caf\u{e9}", replacement: "coffee"
    ).applying(to: source)
  }
}

@Test func writingToolsExcludesFrontmatterAndCodeOnlyInsideBoundary() {
  let source = "---\ntitle: test\n---\n日本語 `code`\n```swift\nlet x = 1\n```\n"
  let boundary = NSRange(location: 20, length: (source as NSString).length - 20)
  let ranges = MarkdownSyntax.ignoredWritingToolsRanges(in: source, enclosing: boundary)
  #expect(!ranges.isEmpty)
  #expect(ranges.allSatisfy { NSIntersectionRange($0, boundary) == $0 })
  #expect(ranges.contains { (source as NSString).substring(with: $0).contains("let x") })
}

@Test func writingToolsProtectsLongFencesUntilAnActualClosingDelimiter() {
  let source = "Before\n````swift\n```\nlet value = 1\n```` not a closer\n~~~~\n`````\nAfter"
  let ranges = MarkdownSyntax.ignoredWritingToolsRanges(
    in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
  #expect(ranges.count == 1)
  #expect(
    (source as NSString).substring(with: ranges[0])
      == "````swift\n```\nlet value = 1\n```` not a closer\n~~~~\n`````\n")
}

@Test func writingToolsProtectsTildeAndContainerFencesIncludingUnclosedCode() {
  let source = "Prose\n> ~~~~ js\n> `value`\n> ~~~~\n\n- ```swift\n  let value = 1"
  let ranges = MarkdownSyntax.ignoredWritingToolsRanges(
    in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
  #expect(
    ranges.map { (source as NSString).substring(with: $0) } == [
      "> ~~~~ js\n> `value`\n> ~~~~\n", "- ```swift\n  let value = 1",
    ])
}

@Test func listItemsInsideFencedCodeAreNotClosingDelimiters() {
  let source = "```\n- ```\nStill protected\n```\nProse"
  let ranges = MarkdownSyntax.ignoredWritingToolsRanges(
    in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
  #expect(ranges == [(source as NSString).range(of: "```\n- ```\nStill protected\n```\n")])
}

@Test func writingToolsProtectsMatchingCodeSpansAcrossLinesAndEscapedOpeners() {
  let source = #"""
    日本語 👩🏽‍💻 ``a ` b`` and `two
    lines` then \`not code and \``still code` and `closed\`
    """#
  let ranges = MarkdownSyntax.ignoredWritingToolsRanges(
    in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
  #expect(
    ranges.map { (source as NSString).substring(with: $0) } == [
      "``a ` b``", "`two\nlines`", "`still code`", #"`closed\`"#,
    ])
  #expect(ranges.allSatisfy { Range($0, in: source) != nil })
}

@Test func unmatchedTicksDoNotHideProseOrCrossParagraphsAndProtectedBlocks() {
  for source in ["a ` lone delimiter", "`first\n\nsecond`", "`first\n~~~\ncode\n~~~\nlast`"] {
    let ranges = MarkdownSyntax.ignoredWritingToolsRanges(
      in: source, enclosing: NSRange(location: 0, length: source.utf16.count))
    #expect(!ranges.contains { (source as NSString).substring(with: $0).contains("first") })
  }
}

@Test func writingToolsFrontmatterUsesExactUTF16BoundariesAndClipsInsideCode() {
  let source = "---\r\ntitle: 日本語 👨‍👩‍👧‍👦\r\n...\r\nProse `cafe\u{301}` after"
  let full = NSRange(location: 0, length: source.utf16.count)
  let ranges = MarkdownSyntax.ignoredWritingToolsRanges(in: source, enclosing: full)
  #expect(
    ranges.map { (source as NSString).substring(with: $0) } == [
      "---\r\ntitle: 日本語 👨‍👩‍👧‍👦\r\n...\r\n", "`cafe\u{301}`",
    ])
  let partial = (source as NSString).range(of: "afe\u{301}")
  #expect(MarkdownSyntax.ignoredWritingToolsRanges(in: source, enclosing: partial) == [partial])
  let prose = (source as NSString).range(of: "Prose")
  #expect(MarkdownSyntax.ignoredWritingToolsRanges(in: source, enclosing: prose).isEmpty)
}

@Test func unfinishedFrontmatterIsProtectedConservatively() {
  let source = "---\ntitle: draft\nStill editing metadata"
  let full = NSRange(location: 0, length: source.utf16.count)
  #expect(MarkdownSyntax.ignoredWritingToolsRanges(in: source, enclosing: full) == [full])
}

@Test func syntaxThemeSeparatesContentFromVisibleMarkdownDelimiters() {
  let source = """
    ## A heading ##
    - [ ] Open task
    - [X] Completed task
    [Link label](https://example.com)
    [[Wiki note]]
    *emphasis* and **strong**
    """
  let spans = MarkdownSyntax.spans(in: source)
  func strings(_ kind: MarkdownSyntax.Kind) -> [String] {
    spans.filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
  }
  #expect(strings(.heading) == ["A heading"])
  #expect(strings(.task) == ["[ ]"])
  #expect(strings(.checkedTask) == ["[X]"])
  #expect(strings(.link) == ["Link label", "Wiki note"])
  #expect(strings(.linkDestination) == ["https://example.com"])
  #expect(strings(.punctuation).filter { $0 == "##" }.count == 2)
  #expect(strings(.punctuation).filter { $0 == "*" }.count == 2)
  #expect(strings(.punctuation).filter { $0 == "**" }.count == 2)
}

@Test func codeContentOverridesProseStylesButItsDelimitersStayDistinct() {
  let source = "`[literal](url) **not emphasis**`\n```swift\nlet value = 1\n```\n"
  let spans = MarkdownSyntax.spans(in: source)
  let literal = (source as NSString).range(of: "literal")
  #expect(spans.last { NSLocationInRange(literal.location, $0.range) }?.kind == .code)
  let tick = NSRange(location: 0, length: 1)
  #expect(spans.last { NSLocationInRange(tick.location, $0.range) }?.kind == .punctuation)
  let fences = spans.filter {
    $0.kind == .punctuation && (source as NSString).substring(with: $0.range) == "```"
  }
  #expect(fences.count == 2)
}

@Test func longFixtureIsSyntheticAndMultilingual() throws {
  let fixture = try EditorFixture.markdown()
  #expect(fixture.utf16.count > 60_000)
  #expect(fixture.contains("Field note 120"))
  #expect(fixture.contains("日本語"))
  #expect(fixture.contains("العربية"))
  #expect(fixture.contains("👨‍👩‍👧‍👦"))
}
