import Foundation

enum LibraryDateGroup: Hashable, Sendable {
    case today
    case yesterday
    case previousSevenDays
    case previousThirtyDays
    case month(start: Date)
    case year(start: Date)
    case undated

    static func group(
        for updatedAt: Date?, relativeTo now: Date, calendar: Calendar
    ) -> LibraryDateGroup {
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

    fileprivate var sortKey: (rank: Int, recency: TimeInterval) {
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

struct LibraryDateSection: Identifiable, Equatable, Sendable {
    let group: LibraryDateGroup
    let notes: [LibraryNote]

    var id: LibraryDateGroup { group }

    static func sections(
        for notes: [LibraryNote], relativeTo now: Date, calendar: Calendar
    ) -> [LibraryDateSection] {
        var buckets: [LibraryDateGroup: [LibraryNote]] = [:]
        for note in notes {
            let group = LibraryDateGroup.group(for: note.updatedAt, relativeTo: now, calendar: calendar)
            buckets[group, default: []].append(note)
        }
        return buckets
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .map { entry in
                let members = entry.key == .undated
                    ? entry.value
                    : entry.value.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                return LibraryDateSection(group: entry.key, notes: members)
            }
    }
}
