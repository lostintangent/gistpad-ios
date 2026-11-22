import Foundation

enum DateGroup: Hashable, Sendable {
    case today
    case yesterday
    case previousSevenDays
    case previousThirtyDays
    case month(start: Date)
    case year(start: Date)
    case undated

    static func group(
        for updatedAt: Date?, relativeTo now: Date, calendar: Calendar
    ) -> DateGroup {
        guard let updatedAt else { return .undated }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: updatedAt),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2...7: return .previousSevenDays
        case 8...30: return .previousThirtyDays
        default:
            if calendar.isDate(updatedAt, equalTo: now, toGranularity: .year) {
                return .month(start: calendar.dateInterval(of: .month, for: updatedAt)?.start ?? updatedAt)
            }
            return .year(start: calendar.dateInterval(of: .year, for: updatedAt)?.start ?? updatedAt)
        }
    }

    func title(locale: Locale, calendar: Calendar) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch self {
        case .today:
            return String(localized: "Today", bundle: .module, locale: locale)
        case .yesterday:
            return String(localized: "Yesterday", bundle: .module, locale: locale)
        case .previousSevenDays:
            return String(localized: "Previous 7 Days", bundle: .module, locale: locale)
        case .previousThirtyDays:
            return String(localized: "Previous 30 Days", bundle: .module, locale: locale)
        case .month(let start):
            return start.formatted(style.month(.wide))
        case .year(let start):
            return start.formatted(style.year())
        case .undated:
            return ""
        }
    }

    /// Groups gists like Notes, newest group first, and keeps their order within each group.
    static func sections(
        for gists: [GistItem], relativeTo now: Date, calendar: Calendar
    ) -> [(group: DateGroup, gists: [GistItem])] {
        Dictionary(grouping: gists) { group(for: $0.updatedAt, relativeTo: now, calendar: calendar) }
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .map { (group: $0.key, gists: $0.value) }
    }

    private var sortKey: (rank: Int, recency: TimeInterval) {
        switch self {
        case .today: (0, 0)
        case .yesterday: (1, 0)
        case .previousSevenDays: (2, 0)
        case .previousThirtyDays: (3, 0)
        case .month(let start): (4, -start.timeIntervalSinceReferenceDate)
        case .year(let start): (5, -start.timeIntervalSinceReferenceDate)
        case .undated: (6, 0)
        }
    }
}
