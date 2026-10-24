#if canImport(UIKit)
  import GistPadIntelligence
  import GistPadInterface
  import SwiftUI
  import Testing

  @testable import GistPadEditor

  @MainActor
  struct IntelligenceTextTests {
    @Test func removedWordsHaveNonColorMarksAndAddedWordsHaveNonColorEmphasis() {
      let diff = NoteTextDiff(before: "Take teh path.", after: "Take the path.")
      let before = NoteIntelligenceDiffText.attributed(diff.before)
      let after = NoteIntelligenceDiffText.attributed(diff.after)
      let removed = before.runs.filter { $0.strikethroughStyle != nil }
      let added = after.runs.filter { $0.font == .body.weight(.semibold) }
      #expect(removed.count == 1)
      #expect(added.count == 1)
      #expect(removed.allSatisfy { $0.foregroundColor == .secondary })
      #expect(added.allSatisfy { $0.foregroundColor == InterfaceTheme.accent })
      #expect(String(before.characters) == "Take teh path.")
      #expect(String(after.characters) == "Take the path.")
    }

    @Test func formattingNeverInterpretsMarkdownOrChangesLiteralSourceBytes() {
      let original = "👩🏽‍💻 [cafe\u{301}](url)\r\n*old* `code`"
      let replacement = "👩🏽‍💻 [coffee](url)\r\n*new* `code`"
      let diff = NoteTextDiff(before: original, after: replacement)
      let before = NoteIntelligenceDiffText.attributed(diff.before)
      let after = NoteIntelligenceDiffText.attributed(diff.after)
      #expect(String(before.characters).utf8.elementsEqual(original.utf8))
      #expect(String(after.characters).utf8.elementsEqual(replacement.utf8))
      #expect(before.runs.contains { $0.foregroundColor == .primary })
      #expect(after.runs.contains { $0.foregroundColor == .primary })
    }
  }
#endif
