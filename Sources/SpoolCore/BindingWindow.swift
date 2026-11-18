import Foundation

/// The window the menu bar and the panel's top block show.
public enum BindingWindow {
    /// The 5-hour window whenever there is one, even past its reset (it then reads 100%).
    /// Without it, the limit that stops the user first: forecast on, the earliest run-out,
    /// else the lowest remaining; forecast off, the lowest remaining.
    public static func pick(_ items: [Assessment], forecastEnabled: Bool, now: Date) -> Assessment? {
        if let session = items.first(where: { $0.window.kind == .session }) { return session }
        return items.enumerated().min { a, b in
            let ka = key(a.element, forecastEnabled: forecastEnabled, now: now)
            let kb = key(b.element, forecastEnabled: forecastEnabled, now: now)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            return a.offset < b.offset
        }?.element
    }

    /// Lower sorts first: [group, runOut or remaining, kind rank].
    private static func key(_ item: Assessment, forecastEnabled: Bool, now: Date) -> [Double] {
        let w = item.window
        let expired = w.isExpired(at: now)
        let rank: Double = switch w.kind {
        case .session: 0
        case .weekly: 1
        case .weeklyModel: 2
        }
        if forecastEnabled, !expired, case .runsOut(let at) = item.verdict {
            return [0, at.timeIntervalSince1970, rank]
        }
        return [1, expired ? 100 : w.remainingPercent, rank]
    }
}
