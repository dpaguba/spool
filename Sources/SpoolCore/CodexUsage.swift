import Foundation

public enum CodexUsage {
    public static func parse(_ data: Data, observedAt: Date) throws -> (windows: [LimitWindow], planType: String?) {
        let root = try JSONHelpers.object(data)
        let plan = root["plan_type"] as? String
        guard let limit = root["rate_limit"] as? [String: Any] else { return ([], plan) }

        var result: [LimitWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = limit[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let seconds = (w["limit_window_seconds"] as? NSNumber)?.doubleValue,
                  let reset = (w["reset_at"] as? NSNumber)?.doubleValue
            else { continue }
            result.append(LimitWindow(
                provider: .codex, kind: seconds <= 86_400 ? .session : .weekly, usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: reset), length: seconds,
                observedAt: observedAt, source: .codexAPI))
        }
        return (result, plan)
    }
}
