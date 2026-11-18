import Foundation

public enum Verdict: Equatable, Sendable {
    case insufficientData
    case enough(remainingAtReset: Double)
    case runsOut(at: Date)
}

public struct Assessment: Equatable, Sendable {
    public var window: LimitWindow
    public var verdict: Verdict

    public init(window: LimitWindow, verdict: Verdict) {
        self.window = window
        self.verdict = verdict
    }
}

public enum PaceForecaster {
    public static let sessionLookback: TimeInterval = 1_800
    public static let minimumSpan: TimeInterval = 300

    /// The forecast for `window` at `now` from its `samples` (sorted, running maximum).
    ///
    /// Weekly windows use the average rate since the week began. The 5-hour window uses the
    /// larger of two rates, so the forecast follows the last 30 minutes:
    /// - the spread rate: growth since the newest sample at or before `now - 30 min`, over the
    ///   real time since that sample. The store writes a line only on change, so that sample
    ///   can be hours old; a jump that happened meanwhile outside Claude Code (claude.ai, the
    ///   desktop app) is then spread over the whole gap instead of the last half hour.
    /// - the inside slope: growth since the first sample inside the last 30 minutes, when that
    ///   sample is at least `minimumSpan` old. It reacts at once to a burst after an idle gap,
    ///   and leaves out a jump that lands on that first sample.
    public static func verdict(for window: LimitWindow, samples: [UsageSample], now: Date) -> Verdict {
        if window.isExpired(at: now) { return .enough(remainingAtReset: 100) }
        let remaining = window.remainingPercent
        if remaining <= 0 { return .runsOut(at: now) }
        let lookbackStart = now - sessionLookback
        var from = window.kind == .session ? max(window.startsAt, lookbackStart) : window.startsAt
        var usedAtFrom = 0.0
        if from > window.startsAt {
            if let s = samples.last(where: { $0.t <= from }) {
                from = s.t
                usedAtFrom = s.usedPercent
            } else {
                from = window.startsAt
            }
        }
        let span = now.timeIntervalSince(from)
        guard span >= minimumSpan else { return .insufficientData }
        var rate = max(0, window.usedPercent - usedAtFrom) / span
        if window.kind == .session, let first = samples.first(where: { $0.t > lookbackStart }) {
            let insideSpan = now.timeIntervalSince(first.t)
            if insideSpan >= minimumSpan {
                rate = max(rate, max(0, window.usedPercent - first.usedPercent) / insideSpan)
            }
        }
        guard rate > 0 else { return .enough(remainingAtReset: remaining) }
        let runOut = now.addingTimeInterval(remaining / rate)
        return runOut < window.resetsAt
            ? .runsOut(at: runOut)
            : .enough(remainingAtReset: max(0, remaining - rate * window.resetsAt.timeIntervalSince(now)))
    }
}
