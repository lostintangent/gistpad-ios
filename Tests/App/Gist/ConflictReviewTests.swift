import Testing

@testable import GistPad

struct ConflictReviewTests {
    @Test func aCRLFConflictShowsOnlyTheChangedLines() async {
        let lines = await DiffLine.changes(
            from: "One\r\nTwo\r\nThree\r\nFour", to: "1\r\nTwo\r\n3\r\nFour")
        #expect(
            lines.map { "\($0.isAddition ? "+" : "-")\($0.offset) \($0.text)" }
                == ["-0 One", "-2 Three", "+0 1", "+2 3"])
    }
}
