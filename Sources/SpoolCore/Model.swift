import Foundation

public enum Provider: String, Codable, Hashable, Sendable, CaseIterable {
    case claude, codex
}

public enum WindowKind: Codable, Hashable, Sendable {
    case session
    case weekly
    case weeklyModel(String)

    public var isWeekly: Bool {
        switch self {
        case .session: false
        case .weekly, .weeklyModel: true
        }
    }
}

public enum DataSource: String, Codable, Hashable, Sendable {
    case statusline, oauth, codexAPI
}

public enum WindowLength {
    public static let session: TimeInterval = 18_000
    public static let week: TimeInterval = 604_800
}

public struct LimitWindow: Codable, Hashable, Sendable {
    public var provider: Provider
    public var kind: WindowKind
    public var usedPercent: Double
    public var resetsAt: Date
    public var length: TimeInterval
    public var observedAt: Date
    public var source: DataSource

    public init(provider: Provider, kind: WindowKind, usedPercent: Double, resetsAt: Date,
                length: TimeInterval, observedAt: Date, source: DataSource) {
        self.provider = provider
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.length = length
        self.observedAt = observedAt
        self.source = source
    }

    public var startsAt: Date { resetsAt.addingTimeInterval(-length) }

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    /// The used percent as Spool shows it: rounded up, so it never reads lower than the real
    /// use, but 100 only once the limit is reached (99.5 reads 99, not a false "full"); 0 once
    /// the reset has passed (the window starts over empty).
    public func displayedUsedPercent(at now: Date) -> Int {
        if isExpired(at: now) { return 0 }
        let used = Int(min(100, max(0, usedPercent)).rounded(.up))
        return remainingPercent > 0 ? min(used, 99) : used
    }

    public func isExpired(at now: Date) -> Bool { now >= resetsAt }

    public func isSameInstance(as other: LimitWindow) -> Bool {
        provider == other.provider && kind == other.kind
            && abs(resetsAt.timeIntervalSince(other.resetsAt)) <= 120
    }
}

public struct UsageSample: Codable, Hashable, Sendable {
    public var t: Date
    public var usedPercent: Double

    public init(t: Date, usedPercent: Double) {
        self.t = t
        self.usedPercent = usedPercent
    }
}
