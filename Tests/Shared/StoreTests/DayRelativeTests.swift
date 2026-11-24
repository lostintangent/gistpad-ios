import Foundation
import Store
import Testing

struct DayRelativeTests {
    /// Changes read against Saturday, October 24, 2026 in Los Angeles, and Yesterday across both
    /// daylight saving days in two languages.
    @Test(arguments: [
        ("2026-10-24T16:15:00Z", "2026-10-24T19:30:00Z", "en_US", "9:15\u{202F}AM"),
        ("2026-10-25T07:30:00Z", "2026-10-24T19:30:00Z", "en_US", "12:30\u{202F}AM"),
        ("2026-10-24T06:59:00Z", "2026-10-24T19:30:00Z", "en_US", "Yesterday"),
        ("2026-10-22T16:15:00Z", "2026-10-24T19:30:00Z", "en_US", "Thursday"),
        ("2026-10-17T16:15:00Z", "2026-10-24T19:30:00Z", "en_US", "10/17"),
        ("2025-12-31T17:15:00Z", "2026-10-24T19:30:00Z", "en_US", "12/31/2025"),
        ("2026-03-08T08:30:00Z", "2026-03-09T19:00:00Z", "en_US", "Yesterday"),
        ("2026-11-01T07:30:00Z", "2026-11-02T20:00:00Z", "fr_FR", "Hier")
    ])
    func aChangeReadsAgainstTheReferenceDay(change: String, reference: String, locale: String, expected: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        calendar.firstWeekday = 1
        let parse = Date.ISO8601FormatStyle().parse
        #expect(try parse(change).dayRelative(to: parse(reference), locale: Locale(identifier: locale), calendar: calendar)
            == expected)
    }
}
