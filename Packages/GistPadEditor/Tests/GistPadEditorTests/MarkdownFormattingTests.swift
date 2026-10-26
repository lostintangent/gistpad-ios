import Foundation
import Testing

@testable import GistPadEditor

struct MarkdownFormattingTests {
  @Test func orderedReplacementsMapBothSelectionEdgesAtEveryBoundary() throws {
    let source = "before|a123bc|after"
    let boundaries = [0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 11, 11, 11, 11, 12, 13, 14, 15, 16, 17]
    for start in boundaries.indices {
      for end in start..<boundaries.count {
        let edit = SourceEdit(
          range: NSRange(location: 7, length: 6), expected: "a123bc",
          replacements: [
            (NSRange(location: 7, length: 0), "# "),
            (NSRange(location: 8, length: 3), "X"),
            (NSRange(location: 11, length: 2), ""),
          ], selection: NSRange(location: start, length: end - start))
        #expect(
          edit.selection == NSRange(
            location: boundaries[start], length: boundaries[end] - boundaries[start]))
        #expect(
          try edit.mutation.applying(to: source).utf8.elementsEqual("before|# aX|after".utf8))
      }
    }
  }

  @Test func inlineFormattingKeepsUnicodeSelectedAndToggles() throws {
    let source = "日本語 👩🏽‍💻 cafe\u{301}"
    let selection = (source as NSString).range(of: "👩🏽‍💻")
    let edit = try #require(try MarkdownFormatting.edit(.bold, in: source, selection: selection))
    let result = try edit.mutation.applying(to: source)
    #expect(result == "日本語 **👩🏽‍💻** cafe\u{301}")
    #expect((result as NSString).substring(with: edit.selection) == "👩🏽‍💻")
    let undo = try #require(
      try MarkdownFormatting.edit(.bold, in: result, selection: edit.selection))
    #expect(try undo.mutation.applying(to: result).utf8.elementsEqual(source.utf8))
  }

  @Test func italicDoesNotRemoveHalfOfBoldSyntax() throws {
    for selection in [NSRange(location: 0, length: 8), NSRange(location: 2, length: 4)] {
      let edit = try #require(
        try MarkdownFormatting.edit(.italic, in: "**note**", selection: selection))
      #expect(try edit.mutation.applying(to: "**note**") == "***note***")
    }
  }

  @Test func emptyCaretFormattingLeavesAnInsertionPointBetweenMarkers() throws {
    let edit = try #require(
      try MarkdownFormatting.edit(.bold, in: "abc", selection: NSRange(location: 1, length: 0)))
    #expect(try edit.mutation.applying(to: "abc") == "a****bc")
    #expect(edit.selection == NSRange(location: 3, length: 0))
  }

  @Test func formattingRejectsInvalidUTF16Ranges() {
    for selection in [
      NSRange(location: -1, length: 0), NSRange(location: 0, length: 9),
      NSRange(location: 1, length: 0), NSRange(location: 0, length: 1),
    ] {
      #expect(throws: SourceMutation.MutationError.invalidRange) {
        try MarkdownFormatting.edit(.bold, in: "📝", selection: selection)
      }
    }
    #expect(throws: MarkdownFormatting.FormattingError.invalidHeadingLevel) {
      try MarkdownFormatting.edit(.heading(7), in: "", selection: NSRange(location: 0, length: 0))
    }
  }

  @Test func selectedLineBoundaryDoesNotIncludeTheFollowingLine() throws {
    let source = "First\nSecond\nThird"
    let edit = try #require(
      try MarkdownFormatting.edit(
        .heading(2), in: source, selection: NSRange(location: 0, length: 6)))
    #expect(try edit.mutation.applying(to: source) == "## First\nSecond\nThird")
    #expect(edit.selection == NSRange(location: 3, length: 6))
  }

  @Test func headingBodyRemovesClosingSyntaxButPreservesLiteralHashes() throws {
    let source = "## Heading ##\r\n## C#\r\n"
    let edit = try #require(
      try MarkdownFormatting.edit(
        .heading(0), in: source, selection: NSRange(location: 0, length: source.utf16.count)))
    #expect(try edit.mutation.applying(to: source) == "Heading\r\nC#\r\n")
    #expect(edit.selection == NSRange(location: 0, length: 13))
    #expect(
      try MarkdownFormatting.edit(
        .heading(0), in: "Body", selection: NSRange(location: 0, length: 0)) == nil)
  }

  @Test func mixedChecklistsPreserveCheckedStateAndIndentation() throws {
    let source = "  - [X] Done\r\n\t9. Next\r\nPlain"
    let edit = try #require(
      try MarkdownFormatting.edit(
        .checklist, in: source, selection: NSRange(location: 0, length: source.utf16.count)))
    let result = try edit.mutation.applying(to: source)
    #expect(result == "  - [x] Done\r\n\t- [ ] Next\r\n- [ ] Plain")
    #expect(Range(edit.selection, in: result) != nil)
    let toggle = try #require(
      try MarkdownFormatting.edit(
        .checklist, in: result, selection: NSRange(location: 0, length: result.utf16.count)))
    #expect(try toggle.mutation.applying(to: result) == "  Done\r\n\tNext\r\nPlain")
  }

  @Test func numberedListConversionUsesOneMutationAndMapsTheCaret() throws {
    let source = "- One\n* Two"
    let selection = NSRange(location: 0, length: source.utf16.count)
    let edit = try #require(
      try MarkdownFormatting.edit(.numberedList, in: source, selection: selection))
    #expect(try edit.mutation.applying(to: source) == "1. One\n2. Two")
    #expect(edit.selection == NSRange(location: 0, length: 13))
    let caret = try #require(
      try MarkdownFormatting.edit(
        .bulletList, in: "  note", selection: NSRange(location: 4, length: 0)))
    #expect(caret.selection == NSRange(location: 6, length: 0))
  }

  @Test func inlineCodeUsesSafeDelimitersAndCanBeRemoved() throws {
    let source = "a ` b"
    let edit = try #require(
      try MarkdownFormatting.edit(
        .inlineCode, in: source, selection: NSRange(location: 0, length: source.utf16.count)))
    let result = try edit.mutation.applying(to: source)
    #expect(result == "``a ` b``")
    let toggle = try #require(
      try MarkdownFormatting.edit(.inlineCode, in: result, selection: edit.selection))
    #expect(try toggle.mutation.applying(to: result) == source)
    let padded = try #require(
      try MarkdownFormatting.edit(
        .inlineCode, in: "`hello", selection: NSRange(location: 0, length: 6)))
    #expect(try padded.mutation.applying(to: "`hello") == "`` `hello ``")
    let paddedSource = try padded.mutation.applying(to: "`hello")
    let unpadded = try #require(
      try MarkdownFormatting.edit(.inlineCode, in: paddedSource, selection: padded.selection))
    #expect(try unpadded.mutation.applying(to: paddedSource) == "`hello")
  }

  @Test func fencedCodeRetainsCRLFAndCannotCloseEarly() throws {
    let source = "a\r\n```\r\nb\r\n"
    let edit = try #require(
      try MarkdownFormatting.edit(
        .codeBlock, in: source, selection: NSRange(location: 0, length: source.utf16.count)))
    #expect(try edit.mutation.applying(to: source) == "````\r\na\r\n```\r\nb\r\n````\r\n")
    #expect(edit.selection == NSRange(location: 6, length: source.utf16.count))
  }

  @Test func linkEscapesLabelsAndParenthesizedDestinations() throws {
    let edit = try #require(
      try MarkdownFormatting.edit(
        .link(label: "A [draft]", destination: "https://example.com/a(b)"),
        in: "note", selection: NSRange(location: 0, length: 4)))
    #expect(try edit.mutation.applying(to: "note") == "[A \\[draft\\]](<https://example.com/a(b)>)")
  }

  @Test func linkRejectsUnsafeOrIncompleteDestinations() {
    for destination in [
      "", "example.com", "javascript:alert(1)", "https://", "mailto:", "tel:",
      "https://a.test/\nnext",
    ] {
      #expect(throws: MarkdownFormatting.FormattingError.invalidLink) {
        try MarkdownFormatting.edit(
          .link(label: "note", destination: destination),
          in: "note", selection: NSRange(location: 0, length: 4))
      }
    }
  }
}
