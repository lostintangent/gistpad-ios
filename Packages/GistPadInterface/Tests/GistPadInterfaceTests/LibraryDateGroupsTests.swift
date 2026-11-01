import Foundation
import Testing

@testable import GistPadInterface

struct LibraryDateGroupsTests {
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

    @Test func updatesCountCalendarDaysNotElapsedHours() throws {
        let now = "2026-10-24T00:10:00Z"
        #expect(try group("2026-10-24T00:05:00Z", now: now) == .today)
        #expect(try group("2026-10-23T23:59:00Z", now: now) == .yesterday)
    }

    @Test func calendarDaysFollowTheReadersTimeZone() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try date("2026-10-24T08:00:00Z")
        #expect(LibraryDateGroup.group(
            for: try date("2026-10-23T06:30:00Z"), relativeTo: now,
            calendar: losAngeles) == .previousSevenDays)
        #expect(LibraryDateGroup.group(
            for: try date("2026-10-24T06:30:00Z"), relativeTo: now,
            calendar: losAngeles) == .yesterday)
    }

    @Test func previousMonthCrossesIntoTheLastYearAsAYearGroup() throws {
        let now = "2026-01-01T09:00:00Z"
        #expect(try group("2025-12-31T20:00:00Z", now: now) == .yesterday)
        #expect(try group("2025-12-26T09:00:00Z", now: now) == .previousSevenDays)
        #expect(try group("2025-12-24T09:00:00Z", now: now) == .previousThirtyDays)
        #expect(try group("2025-12-01T12:00:00Z", now: now) == .year(start: try date("2025-01-01T00:00:00Z")))
    }

    @Test func undatedUpdatesNeverGetAGuessedDate() throws {
        #expect(LibraryDateGroup.group(
            for: nil, relativeTo: try date("2026-10-24T12:30:00Z"), calendar: calendar) == .undated)
    }

    @Test func sectionsAreNewestGroupFirstWithUndatedLastAndNotesNewestFirst() throws {
        let now = try date("2026-10-24T12:30:00Z")
        let notes = [
            note("old-2025", "2025-06-01T09:00:00Z"),
            note("undated", nil),
            note("august", "2026-08-10T09:00:00Z"),
            note("today-early", "2026-10-24T02:00:00Z"),
            note("week", "2026-10-20T09:00:00Z"),
            note("today-late", "2026-10-24T11:00:00Z")
        ]
        let sections = LibraryDateSection.sections(for: notes, relativeTo: now, calendar: calendar)

        #expect(sections.map { $0.group.title(locale: locale, calendar: calendar) }
            == ["Today", "Previous 7 Days", "August", "2025", ""])
        #expect(sections.map { $0.notes.map(\.id) }
            == [["today-late", "today-early"], ["week"], ["august"], ["old-2025"], ["undated"]])
    }

    @Test func emptyGroupsDoNotProduceSections() throws {
        let sections = LibraryDateSection.sections(
            for: [note("only", "2026-10-24T02:00:00Z")],
            relativeTo: try date("2026-10-24T12:30:00Z"), calendar: calendar)
        #expect(sections.map(\.group) == [.today])
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        value.firstWeekday = 1
        return value
    }

    private func group(_ updatedAt: String?, now: String) throws -> LibraryDateGroup {
        LibraryDateGroup.group(
            for: try updatedAt.map { try date($0) }, relativeTo: try date(now), calendar: calendar)
    }

    private func note(_ id: String, _ updatedAt: String?) -> LibraryNote {
        LibraryNote(
            id: id, title: id,
            updatedAt: updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    private func date(_ timestamp: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: timestamp))
    }
}
