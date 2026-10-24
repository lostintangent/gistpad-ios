import Foundation
import Testing

@testable import GistPad

@MainActor
struct NotebookExcerptTests {
  struct Example: Sendable {
    let source: String
    let expected: String?
  }

  @Test(arguments: [
    Example(
      source: "# 📚 Manga reading list\n\nRead **Vagabond** with [friends](https://example.com).",
      expected: "Read Vagabond with friends."),
    Example(
      source: "## 📆 2026-10-24\n\n- [x] Clean **the kitchen**\n- [ ] Call [Alex](https://example.com)",
      expected: "Clean the kitchen\nCall Alex"),
    Example(
      source: "---\nedit:\n  commands:\n    stop: true\n---\n\n# Manga\n\n<ins>Vagabond</ins> is a favorite.",
      expected: "Vagabond is a favorite."),
    Example(
      source: "---\r\n日本語: 🪴\r\n---\r\n\r\n# 日記\r\n\r\n今日は **公園** へ。",
      expected: "今日は 公園 へ。"),
    Example(
      source: "---\nprivate: metadata\n# Not a closed front matter block",
      expected: nil),
    Example(source: "---  \nprivate: metadata", expected: nil),
    Example(source: "---\nprivate: metadata\n---", expected: nil),
    Example(source: "# Just a title", expected: nil),
    Example(source: "## A useful section\n\nKeep its context.", expected: "A useful section\nKeep its context."),
    Example(source: "A title\n=======\n\nA useful thought.", expected: "A useful thought."),
    Example(
      source: "A first thought.\n\n---\n\nA second thought.",
      expected: "A first thought.\nA second thought."),
    Example(
      source: "# A diagram\n\n```mermaid\ngraph TD\nA --> B\n```\n\nKeep the useful words.",
      expected: "Keep the useful words."),
    Example(source: "# Code only\n\n```swift\nlet privateValue = 1\n```", expected: nil),
    Example(
      source: "# A list\n\n1. Read `Swift`\n2. Keep ~~old~~ useful thoughts\n\n![A real diagram](https://example.com/image.png)",
      expected: "Read Swift\nKeep old useful thoughts\nA real diagram"),
    Example(
      source: "- [x] One\n- [ ] Two\nA continued thought.",
      expected: "One\nTwo\nA continued thought."),
    Example(source: "Keep [x] as a literal reference.", expected: "Keep [x] as a literal reference."),
  ])
  func cachedMarkdownBecomesReadableExcerptText(example: Example) {
    #expect(NotebookExcerpt.text(from: example.source) == example.expected)
  }

  @Test func aLeadingLowerLevelTitleIsOmittedOnlyWhenItMatchesTheDocumentTitle() {
    #expect(NotebookExcerpt.text(
      from: "## 📚 Manga reading list\n\nRead **Vagabond**.",
      title: "📚 Manga reading list") == "Read Vagabond.")
    #expect(NotebookExcerpt.text(
      from: "## Currently reading\n\nRead **Vagabond**.",
      title: "📚 Manga reading list") == "Currently reading\nRead Vagabond.")
  }

  @Test func extractionPrecedesEverySurfaceLimitAndNeverMutatesSource() throws {
    let body = String(repeating: "日本語と🪴 ", count: 70)
    let source = "---\n" + String(repeating: "metadata: long value\n", count: 100)
      + "---\n\n# A title\n\n" + body
    let original = Array(source.utf8)
    let text = try #require(NotebookExcerpt.text(from: source))
    #expect(text == body.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(text.count > 280)
    #expect(Array(source.utf8) == original)
  }
}
