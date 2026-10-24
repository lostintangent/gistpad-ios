import Foundation
import Testing
@testable import GistPadInterface

struct NoteFileMenuTests {
    @Test func ordinaryFilesKeepTheirExactNamesAndSuppliedOrder() {
        let files = [
            NoteFile(id: "readme", filename: "README.md"),
            NoteFile(id: "notes", filename: "Notes and ideas.md")
        ]
        let menu = NoteFileMenu(files: files)
        #expect(menu.years.isEmpty)
        #expect(menu.otherFiles == files)
    }

    @Test func datedFilesGroupByDescendingGregorianYearMonthAndDay() throws {
        let files = try [
            file("10-02-2026.md", date: "2026-10-02"),
            file("12-31-2025.md", date: "2025-12-31"),
            file("10-23-2026.md", date: "2026-10-23"),
            file("11-01-2026.md", date: "2026-11-01")
        ]
        let menu = NoteFileMenu(files: files)
        #expect(menu.years.map(\.id) == [2026, 2025])
        #expect(menu.years[0].months.map(\.id) == [11, 10])
        #expect(menu.years[0].months[1].files.map(\.filename) == ["10-23-2026.md", "10-02-2026.md"])
        #expect(menu.years.flatMap(\.files).count == files.count)
    }

    @Test func ungroupedFilesRemainVisibleBesideDateGroups() throws {
        let readme = NoteFile(id: "readme", filename: "README.md")
        let day = try file("2026-01-01.md", date: "2026-01-01")
        let menu = NoteFileMenu(files: [readme, day])
        #expect(menu.otherFiles == [readme])
        #expect(menu.years[0].id == 2026)
        #expect(menu.years[0].months[0].id == 1)
        #expect(menu.years[0].files == [day])
    }

    @Test func equalDatesSortDeterministicallyWithoutDroppingFiles() throws {
        let later = try file("z.md", date: "2026-10-23")
        let first = try file("a.md", date: "2026-10-23")
        #expect(NoteFileMenu(files: [later, first]).years[0].files == [first, later])
    }

    @Test func filenamesWithoutDetectedDatesAreNeverGuessedIntoGroups() {
        let files = [
            NoteFile(id: "year", filename: "2026.md"),
            NoteFile(id: "invalid", filename: "2026-02-30.md"),
            NoteFile(id: "ordinary", filename: "2026-10-23.md")
        ]
        let menu = NoteFileMenu(files: files)
        #expect(menu.years.isEmpty)
        #expect(menu.otherFiles == files)
    }

    private func file(_ filename: String, date: String) throws -> NoteFile {
        let value = try #require(ISO8601DateFormatter().date(from: date + "T00:00:00Z"))
        return NoteFile(id: filename, filename: filename, date: value)
    }
}
