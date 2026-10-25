import Foundation
import Testing

@testable import GistPadInterface

struct LibraryDatePresentationTests {
    @Test(arguments: [
        ("2026-10-23T09:15:00Z", "Yesterday"),
        ("2026-10-22T09:15:00Z", "Thursday"),
        ("2026-10-18T09:15:00Z", "Sunday"),
        ("2026-10-17T09:15:00Z", "10/17"),
        ("2025-10-23T09:15:00Z", "10/23/2025")
    ])
    func updatesUseCalendarDaysAndAQuietLocalizedDate(timestamp: String, expected: String) throws {
        #expect(LibraryDatePresentation.updateLabel(
            for: try date(timestamp), relativeTo: try date("2026-10-24T12:30:00Z"),
            locale: Locale(identifier: "en_US"), calendar: calendar) == expected)
    }

    @Test func todaysUpdateUsesTheLocalTimeWithoutATickingRelativeLabel() throws {
        let updated = try date("2026-10-24T09:15:00Z")
        let locale = Locale(identifier: "en_US")
        let expected = updated.formatted(Date.FormatStyle(
            time: .shortened, locale: locale, calendar: calendar, timeZone: .gmt))
        #expect(LibraryDatePresentation.updateLabel(
            for: updated, relativeTo: try date("2026-10-24T12:30:00Z"),
            locale: locale, calendar: calendar) == expected)
    }

    @Test func yesterdayUsesTheLocalDayAcrossADaylightSavingChange() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(LibraryDatePresentation.updateLabel(
            for: try date("2026-11-01T07:30:00Z"),
            relativeTo: try date("2026-11-02T08:15:00Z"),
            locale: Locale(identifier: "en_US"), calendar: local) == "Yesterday")
    }

    @Test func dailyTitlesIncludeTheWeekdayAndOnlyTheNeededYear() throws {
        let now = try date("2026-10-24T12:30:00Z")
        let locale = Locale(identifier: "en_US")
        #expect(LibraryDatePresentation.dailyTitle(
            for: try date("2026-10-23T00:00:00Z"), relativeTo: now,
            locale: locale, calendar: calendar) == "Friday, Oct 23")
        #expect(LibraryDatePresentation.dailyTitle(
            for: try date("2025-10-23T00:00:00Z"), relativeTo: now,
            locale: locale, calendar: calendar).contains("2025"))
    }

    @Test func dailyTitlesFollowTheReadersLocale() throws {
        let title = LibraryDatePresentation.dailyTitle(
            for: try date("2026-10-23T00:00:00Z"),
            relativeTo: try date("2026-10-24T12:30:00Z"),
            locale: Locale(identifier: "fr_FR"), calendar: calendar)
        #expect(title.localizedCaseInsensitiveContains("vendredi"))
        let day = try #require(title.range(of: "23"))
        let month = try #require(title.range(of: "oct"))
        #expect(day.lowerBound < month.lowerBound)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        value.firstWeekday = 1
        return value
    }

    private func date(_ timestamp: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: timestamp))
    }
}
