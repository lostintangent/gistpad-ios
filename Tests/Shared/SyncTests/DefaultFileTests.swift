import Foundation
import Testing
@testable import Sync

@Suite struct DefaultFileTests {
    @Test(arguments: [
        (["Apple.md", "README.md", "Zebra.md"], "README.md"),
        (["Apple.md", "Zebra.md"], "Apple.md"),
        (["README.md", "2026-10-22.md", "2026-10-24.md"], "2026-10-24.md"),
        (["readme.md", "2026-10-22.md", "2026-10-24.md"], "2026-10-24.md"),
        (["README.md", "12-31-2025.md", "01-01-2026.md"], "01-01-2026.md"),
        (["README.md", "2026-01.md", "2025-12.md"], "2026-01.md"),
        (["README.md", "2026.md", "2025.md"], "2026.md"),
        (["README.md", "2026-02-30.md"], "README.md"),
        (["README.md", "2026-10-24.md", "Other.md"], "README.md"),
        (["README.md", "2026-10-24.md", "10-23-2026.md"], "README.md"),
        (["README.md", "٢٠٢٦-١٠-٢٤.md"], "README.md"),
        (["README.md"], "README.md"),
    ])
    func matchesWebDateThenReadmeThenFallback(filenames: [String], expected: String) throws {
        let gist = try makeGist(filenames)
        #expect(gist.defaultMarkdownFilename == expected)
    }

    @Test func groupingExcludesReadmeYearOnlyAndNonuniformSeries() throws {
        let gist = try makeGist(["README.md", "2026-10-01.md", "2026-11-02.md"])
        #expect(gist.fileDatesForGrouping.count == 2)
        #expect(gist.fileDatesForGrouping["README.md"] == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(gist.fileDatesForGrouping["2026-10-01.md"])
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 10)
        #expect(components.day == 1)
        #expect(components.hour == 0)
        #expect(try makeGist(["README.md", "2025.md", "2026.md"]).fileDatesForGrouping.isEmpty)
        #expect(try makeGist(["README.md", "2026-10-01.md", "Other.md"]).fileDatesForGrouping.isEmpty)
    }

    private func makeGist(_ filenames: [String]) throws -> Gist {
        let json: [String: Any] = [
            "id": "test", "description": "Note", "public": false,
            "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
            "files": Dictionary(uniqueKeysWithValues: filenames.map {
                ($0, ["filename": $0, "language": "Markdown", "content": $0])
            }),
        ]
        return try decodeGist(JSONSerialization.data(withJSONObject: json))
    }
}
