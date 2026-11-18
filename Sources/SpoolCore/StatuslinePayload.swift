import Foundation

public enum StatuslinePayload {
    /// Reads only `rate_limits`; every other field is ignored. Each window may be absent on its own.
    public static func windows(from data: Data, observedAt: Date) throws -> [LimitWindow] {
        let object = try JSONHelpers.object(data)
        guard let limits = object["rate_limits"] as? [String: Any] else { return [] }

        var result: [LimitWindow] = []
        for (key, kind, length) in [
            ("five_hour", WindowKind.session, WindowLength.session),
            ("seven_day", WindowKind.weekly, WindowLength.week),
        ] {
            guard let w = limits[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue
            else { continue }
            result.append(LimitWindow(
                provider: .claude, kind: kind, usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: reset), length: length,
                observedAt: observedAt, source: .statusline))
        }
        return result
    }
}
