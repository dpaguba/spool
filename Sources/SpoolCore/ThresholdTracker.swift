import Foundation

/// Decides when to notify that a usage threshold of the 5-hour window was crossed, once per window.
public struct ThresholdTracker: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var provider: Provider
        var resetsAt: Date
        var fired: Set<Double>
    }

    var entries: [Entry] = []

    var entryCount: Int { entries.count }

    public init() {}

    /// Returns the highest newly crossed threshold, or nil. Only session windows are tracked.
    public mutating func evaluate(_ window: LimitWindow, thresholds: [Double], now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-86_400)
        entries.removeAll { $0.resetsAt < cutoff }

        guard window.kind == .session else { return nil }

        let index: Int
        if let i = entries.firstIndex(where: {
            $0.provider == window.provider && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) <= 120
        }) {
            index = i
        } else {
            entries.append(Entry(provider: window.provider, resetsAt: window.resetsAt, fired: []))
            index = entries.count - 1
        }

        let crossed = thresholds.filter { window.usedPercent >= $0 }
        let fresh = crossed.filter { !entries[index].fired.contains($0) }
        entries[index].fired.formUnion(crossed)
        return fresh.max()
    }
}
