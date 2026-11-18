import Foundation

/// What changes when Claude Code writes its login, read without the secret: the Keychain
/// item's modification date (`mdat`, from an attribute query that prints no password) and
/// the credentials file's modification time.
public struct LoginStamp: Equatable, Sendable {
    public var keychainModified: String?
    public var fileModified: Date?

    public init(keychainModified: String? = nil, fileModified: Date? = nil) {
        self.keychainModified = keychainModified
        self.fileModified = fileModified
    }

    /// The `mdat` value in what `security find-generic-password` prints without `-w`, such as
    /// `20261110203015Z`; nil when there is none.
    public static func keychainModified(fromAttributes output: Data) -> String? {
        let text = String(decoding: output, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.contains("\"mdat\"<timedate>=") {
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            // "mdat"<timedate>=0x...  "20261110203015Z\000": the last quoted part is the date.
            guard quoted.count >= 4 else { return nil }
            let value = quoted[quoted.count - 2]
            return String(value.hasSuffix("\\000") ? value.dropLast(4) : value)
        }
        return nil
    }
}

/// Keeps Detailed limits from reading Claude Code's secret again right after it found the
/// token expired, or the usage request refused it: the next read waits until
/// `FetchGate.minimumInterval` has passed or the login's stamp has changed, so a dead login
/// does not raise a Keychain prompt on every panel open.
public struct ExpiredLoginPause: Equatable, Sendable {
    private var since: Date?
    private var stamp: LoginStamp?

    public init() {}

    /// The token read at `now` had expired, or was refused; `stamp` was taken before that read.
    public mutating func record(now: Date, stamp: LoginStamp) {
        since = now
        self.stamp = stamp
    }

    /// A read found something other than an expired token.
    public mutating func clear() {
        since = nil
        stamp = nil
    }

    public func allowsRead(now: Date, stamp: LoginStamp) -> Bool {
        guard let since, let recorded = self.stamp else { return true }
        return now.timeIntervalSince(since) >= FetchGate.minimumInterval || stamp != recorded
    }
}

/// What a usage request that failed with an HTTP status (other than 429) does to the next one.
public enum FailedRequest {
    public enum Action: Equatable, Sendable {
        /// Wait for the owning app to write a new login (`ExpiredLoginPause`); the gate's
        /// backoff does not grow.
        case pauseUntilLoginChanges
        /// `FetchGate.recordFailure`: exponential, up to `FetchGate.maximumBackoff`.
        case backOff
    }

    /// 401 and 403 from Claude's usage endpoint mean the token was refused before its expiry
    /// time (revoked, or replaced by a new login). Backing off for up to 4 hours would ignore
    /// the fresh login Claude Code writes next, so Claude waits for that instead. Codex keeps
    /// backing off: Spool has no stamp of its login to watch.
    public static func action(forStatus code: Int, provider: Provider) -> Action {
        provider == .claude && (code == 401 || code == 403) ? .pauseUntilLoginChanges : .backOff
    }
}

/// Refusals (HTTP 401 or 403) of Claude Code's login by the usage endpoint. The first refusal
/// of a login only pauses (`ExpiredLoginPause`), since Claude Code usually writes a new login
/// soon; the same login refused again also backs off like any failure, so a lasting refusal
/// (a token without the right scope) is not retried every 15 minutes. A new login
/// goes ahead at once, without the backoff its predecessor earned.
public struct LoginRefusals: Equatable, Sendable {
    /// Stamp of the login refused last; nil when the latest outcome was not a refusal.
    private var refused: LoginStamp?

    public init() {}

    /// Whether a refusal is on record, so a closed gate is worth a look at the login's stamp.
    public var isActive: Bool { refused != nil }

    /// Records a refusal of the login with `stamp`, taken before its read, at `now`. Backs
    /// `gate` off when the same login was refused before; returns whether it did.
    @discardableResult
    public mutating func recordRefusal(stamp: LoginStamp, now: Date, gate: inout FetchGate) -> Bool {
        let repeated = refused == stamp
        refused = stamp
        if repeated { gate.recordFailure(now: now) }
        return repeated
    }

    /// Opens `gate` now when the refused login has since been replaced by one with `stamp`;
    /// returns whether it did.
    public func openForNewLogin(stamp: LoginStamp, gate: inout FetchGate) -> Bool {
        guard let refused, refused != stamp else { return false }
        gate.reset()
        return true
    }

    /// The latest attempt ended in something other than a refusal.
    public mutating func clear() {
        refused = nil
    }
}
