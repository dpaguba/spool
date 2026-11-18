import Foundation

public enum ClaudeOAuthUsage {
    /// Prefers the windows of `limits[]`; when it is missing, empty or yields no window, falls
    /// back to the flat keys. `resets_at` is an ISO-8601 string or epoch seconds.
    /// `limits[].percent` is read as 0-100 like `utilization`; not yet checked against a live
    /// response.
    public static func windows(from data: Data, observedAt: Date) throws -> [LimitWindow] {
        let root = try JSONHelpers.object(data)

        func make(_ kind: WindowKind, _ percent: Any?, _ reset: Any?) -> LimitWindow? {
            guard let used = (percent as? NSNumber)?.doubleValue,
                  let resets = resetDate(reset)
            else { return nil }
            return LimitWindow(
                provider: .claude, kind: kind, usedPercent: used, resetsAt: resets,
                length: kind.isWeekly ? WindowLength.week : WindowLength.session,
                observedAt: observedAt, source: .oauth)
        }

        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            var result: [LimitWindow] = []
            for entry in limits {
                let kind: WindowKind
                switch entry["kind"] as? String {
                case "session": kind = .session
                case "weekly_all": kind = .weekly
                case "weekly_scoped":
                    guard let scope = entry["scope"] as? [String: Any],
                          let model = scope["model"] as? [String: Any],
                          let name = model["display_name"] as? String, !name.isEmpty
                    else { continue }
                    kind = .weeklyModel(name)
                default: continue
                }
                if let w = make(kind, entry["percent"], entry["resets_at"]) { result.append(w) }
            }
            if !result.isEmpty { return result }
        }

        var result: [LimitWindow] = []
        for (key, kind) in [
            ("five_hour", WindowKind.session),
            ("seven_day", .weekly),
            ("seven_day_opus", .weeklyModel("Opus")),
            ("seven_day_sonnet", .weeklyModel("Sonnet")),
        ] {
            guard let w = root[key] as? [String: Any] else { continue }
            if let window = make(kind, w["utilization"], w["resets_at"]) { result.append(window) }
        }
        return result
    }

    /// An ISO-8601 string or a number of seconds since 1970; nil for anything else.
    static func resetDate(_ value: Any?) -> Date? {
        if let text = value as? String { return parseDate(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
