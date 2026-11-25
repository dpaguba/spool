import Foundation

public enum WindowMerge {
    /// Current state of each (provider, kind): the instance with the latest reset, and within it
    /// the state `samples` ends on.
    public static func current(from observations: [UsageObservation]) -> [LimitWindow] {
        struct Group: Hashable { var provider: Provider; var kind: WindowKind }
        var groups: [Group: [LimitWindow]] = [:]
        var order: [Group] = []
        for window in observations.flatMap(\.windows) {
            let g = Group(provider: window.provider, kind: window.kind)
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(window)
        }
        let sorted = byTime(observations)
        return order.compactMap { g in
            guard let latest = groups[g]?.max(by: { $0.resetsAt < $1.resetsAt }) else { return nil }
            return states(of: latest, in: sorted).last?.window
        }
    }

    /// Samples of one window instance sorted by time: at each observation, the usage as
    /// `current` would report it from the observations up to that one.
    public static func samples(for window: LimitWindow, in observations: [UsageObservation]) -> [UsageSample] {
        states(of: window, in: byTime(observations)).map { UsageSample(t: $0.t, usedPercent: $0.window.usedPercent) }
    }

    // MARK: - Internals

    private static func byTime(_ observations: [UsageObservation]) -> [UsageObservation] {
        observations.enumerated()
            .sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Walks the observations of one window instance in time order and returns the state after each.
    ///
    /// Within one instance usage only grows, so the highest value wins. Weekly windows have two
    /// exceptions:
    /// - A fetched source (the usage API, Codex) answers for the moment it was asked: its value
    ///   replaces the state, also downwards.
    /// - Anthropic can reset a weekly limit before its reset time. The weekly use then drops to 0
    ///   while the reset time stays the same, and a new 5-hour window starts. Claude Code sends
    ///   both windows from one response, so the 5-hour window dates the weekly value: one that
    ///   comes with a newer 5-hour window replaces the state. Idle Claude Code sessions keep
    ///   redrawing their status line with the numbers they last received, with their older
    ///   5-hour window or, once it has ended, without one; those are ignored after newer data.
    private static func states(of target: LimitWindow,
                               in sorted: [UsageObservation]) -> [(t: Date, window: LimitWindow)] {
        var result: [(t: Date, window: LimitWindow)] = []
        var state: LimitWindow?
        /// The newest 5-hour window that came with this instance.
        var anchor: LimitWindow?
        /// Whether the state rests on dated data: a fetched source or a 5-hour window.
        var dated = false
        func raise(_ window: LimitWindow) {
            if let current = state, current.usedPercent >= window.usedPercent { return }
            state = window
        }
        for obs in sorted {
            guard let window = obs.windows.filter({ $0.isSameInstance(as: target) })
                .max(by: { $0.usedPercent < $1.usedPercent }) else { continue }
            let session = obs.windows.filter { $0.provider == target.provider && $0.kind == .session }
                .max { $0.resetsAt < $1.resetsAt }
            if !target.kind.isWeekly {
                // A reset of the 5-hour window always starts a new instance.
                raise(window)
            } else if window.source != .statusline {
                state = window
                dated = true
                if let session, anchor.map({ isNewer(session, than: $0) }) ?? true { anchor = session }
            } else if let session {
                if let current = anchor, !isNewer(session, than: current) {
                    if session.isSameInstance(as: current) { raise(window) }
                } else {
                    anchor = session
                    state = window
                    dated = true
                }
            } else if !dated {
                raise(window)
            }
            if let state { result.append((obs.t, state)) }
        }
        return result
    }

    private static func isNewer(_ window: LimitWindow, than other: LimitWindow) -> Bool {
        window.resetsAt > other.resetsAt && !window.isSameInstance(as: other)
    }
}
