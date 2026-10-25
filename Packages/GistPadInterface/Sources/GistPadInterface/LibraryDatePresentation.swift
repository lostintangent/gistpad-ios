import Foundation

enum LibraryDatePresentation {
    static func updateLabel(
        for date: Date, relativeTo now: Date, locale: Locale, calendar: Calendar
    ) -> String {
        let style = Date.FormatStyle(
            locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", bundle: .module, locale: locale)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(style.weekday(.wide))
        }
        let day = style.month(.defaultDigits).day()
        return date.formatted(
            calendar.isDate(date, equalTo: now, toGranularity: .year) ? day : day.year())
    }

    static func dailyTitle(
        for date: Date, relativeTo now: Date, locale: Locale, calendar: Calendar
    ) -> String {
        let style = Date.FormatStyle(
            locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.abbreviated).day()
        return date.formatted(
            calendar.isDate(date, equalTo: now, toGranularity: .year) ? style : style.year())
    }
}
