import Foundation

/// The `Retry-After` header of a 429 response (RFC 9110 §10.2.3): delay seconds or an HTTP date.
public enum RetryAfter {
    /// Seconds to wait after `now`: the delay as given, or the time until the date (0 when it
    /// has passed). Nil when the header is missing or in neither form.
    public static func interval(_ header: String?, now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            return TimeInterval(value)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
