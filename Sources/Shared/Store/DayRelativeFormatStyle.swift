import Foundation

extension Date {
    /// Dates a change the way Notes lists it, against a reference day: the time that day, then
    /// Yesterday, the weekday that week, and the date before that, with a year only when it differs.
    public struct DayRelativeFormatStyle: Foundation.FormatStyle {
        /// Any moment in the day the date reads against, such as the library's today or a widget
        /// entry's date.
        public var reference: Date
        public var locale: Locale
        public var calendar: Calendar

        public init(reference: Date, locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
            self.reference = reference
            self.locale = locale
            self.calendar = calendar
        }

        public func format(_ date: Date) -> String {
            let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            let day = calendar.startOfDay(for: date)
            let referenceDay = calendar.startOfDay(for: reference)
            switch calendar.dateComponents([.day], from: day, to: referenceDay).day ?? 0 {
            // A change after the reference day reads as a time too, until the day moves.
            case ...0:
                return date.formatted(style.hour().minute())
            case 1:
                return referenceDay.formatted(Date.AnchoredRelativeFormatStyle(
                    anchor: day, allowedFields: [.day], presentation: .named, locale: locale,
                    calendar: calendar, capitalizationContext: .beginningOfSentence))
            default:
                if calendar.isDate(date, equalTo: reference, toGranularity: .weekOfYear) {
                    return date.formatted(style.weekday(.wide))
                }
                let monthDay = style.month(.defaultDigits).day()
                return date.formatted(
                    calendar.isDate(date, equalTo: reference, toGranularity: .year) ? monthDay : monthDay.year())
            }
        }

        public func locale(_ locale: Locale) -> Self {
            var style = self
            style.locale = locale
            return style
        }
    }
}

extension FormatStyle where Self == Date.DayRelativeFormatStyle {
    /// A date read against the day of `reference`: a time, Yesterday, a weekday or a date.
    public static func dayRelative(
        to reference: Date, locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent
    ) -> Self {
        Self(reference: reference, locale: locale, calendar: calendar)
    }
}
