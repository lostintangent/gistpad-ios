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

@Test func longFixtureIsSyntheticAndMultilingual() throws {
  let fixture = try EditorFixture.markdown()
  #expect(fixture.utf16.count > 60_000)
  #expect(fixture.contains("Field note 120"))
  #expect(fixture.contains("日本語"))
  #expect(fixture.contains("العربية"))
  #expect(fixture.contains("👨‍👩‍👧‍👦"))
}
