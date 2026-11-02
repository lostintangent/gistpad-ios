import Foundation
import Testing

@testable import GistPadInterface

struct DateGroupTests {
    private let locale = Locale(identifier: "en_US")

    @Test(arguments: [
        ("2026-10-24T09:15:00Z", "Today"),
        ("2026-10-23T23:59:00Z", "Yesterday"),
        ("2026-10-22T09:15:00Z", "Previous 7 Days"),
        ("2026-10-17T09:15:00Z", "Previous 7 Days"),
        ("2026-10-16T09:15:00Z", "Previous 30 Days"),
        ("2026-09-24T09:15:00Z", "Previous 30 Days"),
        ("2026-09-23T09:15:00Z", "September"),
        ("2026-01-02T09:15:00Z", "January"),
        ("2025-12-31T09:15:00Z", "2025"),
        ("2025-06-01T09:15:00Z", "2025")
    ])
    func datesLandInTheirRelativeGroup(timestamp: String, expectedTitle: String) throws {
        let group = try group(timestamp, now: "2026-10-24T12:30:00Z")
        #expect(group.title(locale: locale, calendar: calendar) == expectedTitle)
    }

    @Test func calendarDaysFollowTheReadersTimeZone() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try date("2026-10-24T08:00:00Z")
        #expect(DateGroup.group(
            for: try date("2026-10-23T06:30:00Z"), relativeTo: now,
            calendar: losAngeles) == .previousSevenDays)
        #expect(DateGroup.group(
            for: try date("2026-10-24T06:30:00Z"), relativeTo: now,
            calendar: losAngeles) == .yesterday)
    }

    @Test func dailyTitlesIncludeTheWeekdayAndOnlyTheNeededYear() throws {
        let now = try date("2026-10-24T12:30:00Z")
        #expect(DateLabels.dailyTitle(
            for: try date("2026-10-23T00:00:00Z"), relativeTo: now,
            locale: locale, calendar: calendar) == "Friday, Oct 23")
        #expect(DateLabels.dailyTitle(
            for: try date("2025-10-23T00:00:00Z"), relativeTo: now,
            locale: locale, calendar: calendar).contains("2025"))
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        value.firstWeekday = 1
        return value
    }

    private func group(_ updatedAt: String?, now: String) throws -> DateGroup {
        DateGroup.group(
            for: try updatedAt.map { try date($0) }, relativeTo: try date(now), calendar: calendar)
    }

    private func date(_ timestamp: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: timestamp))
    }
}
