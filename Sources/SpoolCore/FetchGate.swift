import Foundation

public struct FetchGate: Codable, Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 900
    public static let maximumBackoff: TimeInterval = 14_400

    private var nextAllowed: Date?
    private var failures = 0

    public init() {}

    /// When the next request may go out; nil while nothing has been recorded.
    public var nextAttempt: Date? { nextAllowed }

    public func allows(now: Date) -> Bool {
        guard let nextAllowed else { return true }
        return now >= nextAllowed
    }

    public mutating func recordSuccess(now: Date) {
        failures = 0
        nextAllowed = now.addingTimeInterval(Self.minimumInterval)
    }

    /// Waits for `Retry-After`, at least `minimumInterval` and at most `maximumBackoff`: the
    /// gate is persisted, so an absurd header value would otherwise turn the source off for good.
    public mutating func recordRateLimited(retryAfter: TimeInterval?, now: Date) {
        let delay = min(max(retryAfter ?? Self.minimumInterval, Self.minimumInterval), Self.maximumBackoff)
        nextAllowed = now.addingTimeInterval(delay)
    }

    /// Pulls a next attempt further than `maximumBackoff` from `now` back to that limit. For a
    /// gate saved before the 429 delay had a ceiling, or across a clock set far back.
    public mutating func clamp(now: Date) {
        let latest = now.addingTimeInterval(Self.maximumBackoff)
        if let nextAllowed, nextAllowed > latest { self.nextAllowed = latest }
    }

    /// Open now, with no backoff: for a source whose earlier failures no longer apply (a new
    /// login after a refused one).
    public mutating func reset() {
        self = FetchGate()
    }

    public mutating func recordFailure(now: Date) {
        failures += 1
        let delay = min(Self.minimumInterval * pow(2, Double(min(failures - 1, 10))), Self.maximumBackoff)
        nextAllowed = now.addingTimeInterval(delay)
    }
}
