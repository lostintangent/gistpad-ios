import Foundation
import Testing
import Store

struct DayRelativeFormatStyleTests {
    @Test(arguments: [
        ("2026-10-24T09:15:00Z", "9:15\u{202F}AM"),
        ("2026-10-25T00:30:00Z", "12:30\u{202F}AM"),
        ("2026-10-23T23:59:00Z", "Yesterday"),
        ("2026-10-22T09:15:00Z", "Thursday"),
        ("2026-10-17T09:15:00Z", "10/17"),
        ("2025-12-31T09:15:00Z", "12/31/2025")
    ])
    func aChangeReadsAgainstTheReferenceDay(timestamp: String, expected: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 1
        let style = Date.DayRelativeFormatStyle(
            reference: try date("2026-10-24T12:30:00Z"), locale: Locale(identifier: "en_US"), calendar: calendar)
        #expect(try date(timestamp).formatted(style) == expected)
    }

    @Test(arguments: [
        ("2026-03-08T08:30:00Z", "2026-03-09T19:00:00Z", "en_US", "Yesterday"),
        ("2026-11-01T07:30:00Z", "2026-11-02T20:00:00Z", "en_US", "Yesterday"),
        ("2026-11-01T07:30:00Z", "2026-11-02T20:00:00Z", "fr_FR", "Hier")
    ])
    func yesterdaySpansDaylightSavingDaysInTheReadersLanguage(
        timestamp: String, reference: String, locale: String, expected: String
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(try date(timestamp).formatted(
            .dayRelative(to: date(reference), locale: Locale(identifier: locale), calendar: calendar)) == expected)
    }

    private func date(_ timestamp: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(timestamp)
    }
}
