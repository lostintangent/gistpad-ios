import Foundation

extension Date {
    /// Dates a change the way Notes lists it, against the day of `reference`: the time that day,
    /// then Yesterday, the weekday that week, and the date before that, with a year only when it differs.
    public func dayRelative(to reference: Date, locale: Locale, calendar: Calendar) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day = calendar.startOfDay(for: self), referenceDay = calendar.startOfDay(for: reference)
        switch calendar.dateComponents([.day], from: day, to: referenceDay).day ?? 0 {
        case ...0:
            return formatted(style.hour().minute())
        case 1:
            return referenceDay.formatted(Date.AnchoredRelativeFormatStyle(
                anchor: day, allowedFields: [.day], presentation: .named, locale: locale,
                calendar: calendar, capitalizationContext: .beginningOfSentence))
        default:
            if calendar.isDate(self, equalTo: reference, toGranularity: .weekOfYear) {
                return formatted(style.weekday(.wide))
            }
            let monthDay = style.month(.defaultDigits).day()
            return formatted(calendar.isDate(self, equalTo: reference, toGranularity: .year) ? monthDay : monthDay.year())
        }
    }
}
