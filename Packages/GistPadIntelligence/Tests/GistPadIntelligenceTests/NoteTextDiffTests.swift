import Testing

@testable import GistPadIntelligence

struct NoteTextDiffTests {
  @Test func aSpellingCorrectionMarksOnlyTheChangedWord() {
    let diff = NoteTextDiff(before: "Take teh river path.", after: "Take the river path.")
    #expect(diff.before.filter { $0.kind == .removed }.map(\.text) == ["teh"])
    #expect(diff.after.filter { $0.kind == .added }.map(\.text) == ["the"])
    #expect(
      diff.before.filter { $0.kind == .unchanged }.map(\.text).joined() == "Take  river path.")
    #expect(diff.after.filter { $0.kind == .unchanged }.map(\.text).joined() == "Take  river path.")
  }

  @Test func punctuationAndWhitespaceChangesAreNotNormalizedAway() {
    let before = "  One,\r\n\t“two”  "
    let after = "  One.\r\n\t“two”\t"
    let diff = NoteTextDiff(before: before, after: after)
    #expect(diff.before.filter { $0.kind == .removed }.map(\.text).joined() == ",  ")
    #expect(diff.after.filter { $0.kind == .added }.map(\.text).joined() == ".\t")
    #expect(diff.before.map(\.text).joined().utf8.elementsEqual(before.utf8))
    #expect(diff.after.map(\.text).joined().utf8.elementsEqual(after.utf8))
  }

  @Test func canonicallyEquivalentWordsStillExposeTheExactByteChange() {
    let before = "A cafe\u{301}."
    let after = "A café."
    let diff = NoteTextDiff(before: before, after: after)
    #expect(
      diff.before.filter { $0.kind == .removed }.map(\.text).joined()
        .utf8.elementsEqual("cafe\u{301}".utf8))
    #expect(
      diff.after.filter { $0.kind == .added }.map(\.text).joined()
        .utf8.elementsEqual("café".utf8))
  }

  @Test(arguments: [
    ("", "A new paragraph."),
    ("Remove this paragraph.", ""),
    ("No change.\r\n", "No change.\r\n"),
    ("👩🏽‍💻 cafe\u{301}\r\n👨‍👩‍👧‍👦", "👩🏽‍💻 coffee\r\n👨‍👩‍👧‍👦"),
    ("今日は川を歩きます。", "今日は公園を歩きます。"),
    ("قراءة الملاحظة", "كتابة الملاحظة"),
    ("[title](old) *literal* `code`", "[title](new) *literal* `code`"),
    ("same one same two same", "same two same one same"),
  ])
  func bothSidesPreserveEveryByteAndEveryGraphemeBoundary(pair: (String, String)) {
    let diff = NoteTextDiff(before: pair.0, after: pair.1)
    for (source, runs) in [(pair.0, diff.before), (pair.1, diff.after)] {
      #expect(runs.map(\.text).joined().utf8.elementsEqual(source.utf8))
      var boundaries: Set<Int> = [0]
      var offset = 0
      for character in source {
        offset += String(character).utf8.count
        boundaries.insert(offset)
      }
      offset = 0
      for run in runs {
        offset += run.text.utf8.count
        #expect(boundaries.contains(offset))
      }
    }
    #expect(!diff.before.contains { $0.kind == .added })
    #expect(!diff.after.contains { $0.kind == .removed })
    if pair.0.utf8.elementsEqual(pair.1.utf8) {
      #expect(diff.before.allSatisfy { $0.kind == .unchanged })
      #expect(diff.after.allSatisfy { $0.kind == .unchanged })
    }
  }
}
