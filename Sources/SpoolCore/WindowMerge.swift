import Foundation

public enum WindowMerge {
    /// Current state of each (provider, kind): the instance with the latest reset, highest usage within it.
    public static func current(from observations: [UsageObservation]) -> [LimitWindow] {
        struct Group: Hashable { var provider: Provider; var kind: WindowKind }
        var groups: [Group: [LimitWindow]] = [:]
        var order: [Group] = []
        for window in observations.flatMap(\.windows) {
            let g = Group(provider: window.provider, kind: window.kind)
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(window)
        }
        return order.compactMap { g in
            guard let all = groups[g], let latest = all.max(by: { $0.resetsAt < $1.resetsAt }) else { return nil }
            return all.filter { $0.isSameInstance(as: latest) }
                .max { $0.usedPercent < $1.usedPercent }
        }
    }

    /// Samples of one window instance sorted by time, with usage replaced by its running maximum.
    public static func samples(for window: LimitWindow, in observations: [UsageObservation]) -> [UsageSample] {
        var points: [UsageSample] = []
        for obs in observations {
            let used = obs.windows.filter { $0.isSameInstance(as: window) }.map(\.usedPercent).max()
            if let used { points.append(UsageSample(t: obs.t, usedPercent: used)) }
        }
        points.sort { $0.t < $1.t }
        var running = -Double.infinity
        return points.map { p in
            running = max(running, p.usedPercent)
            return UsageSample(t: p.t, usedPercent: running)
        }
    }
}
