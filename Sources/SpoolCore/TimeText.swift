import Foundation

public enum TimeText {
    public static func time(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        format(date, template: "jmm", locale: locale, timeZone: timeZone)
    }

    public static func dayAndTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        format(date, template: "EEEjmm", locale: locale, timeZone: timeZone)
    }

    /// Short date and time ("Nov 12, 9:00 AM", "12 лист., 09:00"), for points days apart.
    public static func dateAndTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        format(date, template: "MMMdjmm", locale: locale, timeZone: timeZone)
    }

    /// Hours and zero-padded minutes ("1:47"), truncated to whole minutes; a past target gives "0:00".
    public static func countdown(from: Date, to: Date) -> String {
        countdown(minutes: Int(to.timeIntervalSince(from) / 60))
    }

    /// `minutes` as hours and zero-padded minutes ("1:47"); "0:00" for none or fewer.
    public static func countdown(minutes: Int) -> String {
        let minutes = max(0, minutes)
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    private static func format(_ date: Date, template: String, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
        return f.string(from: date)
    }
}
