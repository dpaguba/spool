import Foundation
import SpoolCore

/// Why a check of an optional source brought no new data.
enum FetchProblem: Error, Equatable, Sendable {
    /// No usable login: nothing found, access declined, or nothing Spool can read.
    case noCredentials
    /// The token has expired. Spool never refreshes it and waits for the owning app to.
    case tokenExpired
    case rateLimited(until: Date)
    case http(Int)
    case network
    /// A successful response Spool cannot read.
    case malformed
}

/// What one call to a fetch method did.
struct FetchOutcome: Equatable, Sendable {
    /// The latest attempt's problem; when this call attempted nothing (gate closed, a check
    /// already running, an unchanged dead login), the one before.
    var problem: FetchProblem?
    /// Whether this call read the login, so a login problem in `problem` is news, not a repeat.
    var readLogin: Bool
}

/// What the fetcher knows about one source besides the latest problem, for the settings window.
struct FetchStatus: Equatable, Sendable {
    /// Time of the latest successful request this launch.
    var lastSuccess: Date?
    /// When the source's gate opens again; nil when nothing was ever recorded.
    var nextAttempt: Date?
}

/// Checks the optional sources (Detailed limits, Codex) and appends the
/// windows they report to the store; the file watcher then redraws.
///
/// Read only: a login is read anew for each attempt, kept in memory only while that attempt
/// runs, and sent only in the documented headers of its own request, to the documented host
/// (redirects are refused). Nothing here writes, refreshes or logs a credential.
///
/// Each provider has its own `FetchGate`, persisted in `paths.fetchGates`. While it is closed
/// nothing is read or requested; a failed attempt waits for it to open, with no retries.
actor UsageFetcher {
    private let store: SampleStore
    private let paths: SpoolPaths
    private let session: URLSession
    private let debug = ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1"
    private var gates: Gates
    private var inFlight: Set<Provider> = []
    private var problems: [Provider: FetchProblem] = [:]
    private var successes: [Provider: Date] = [:]
    private var plan: String?
    /// Set when the latest Claude login read found the token expired, or its request got 401 or 403.
    private var expiredPause = ExpiredLoginPause()
    /// Claude logins the usage endpoint refused, so a repeat backs off and a new login does not wait.
    private var refusals = LoginRefusals()

    init(store: SampleStore, paths: SpoolPaths, session: URLSession = UsageFetcher.makeSession()) {
        self.store = store
        self.paths = paths
        self.session = session
        gates = Self.loadGates(from: paths.fetchGates, now: .now)
    }

    /// An ephemeral session without a cache, cookie store or credential store, so nothing of
    /// a request (its `Authorization` header included) or its response is written to disk.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    /// Detailed limits: reads Claude Code's login and asks for the usage when the gate is open.
    /// While the gate is closed, returns the problem of the latest attempt.
    ///
    /// A login read can wait on a Keychain prompt for a long time, so `proceed` is asked after
    /// it: nil (the source was turned off meanwhile) sends nothing; otherwise it is the current
    /// time, from which the expiry check, the gate and the observation count. A failed read
    /// backs off like a failed request, so a declined Keychain prompt does not come back on
    /// every panel open. After an expired token, or a request answered 401 or 403, the secret
    /// is not read again until 15 minutes have passed or Claude Code has rewritten its login
    /// (`ExpiredLoginPause`). The same login refused again also backs off; a new login after
    /// that goes ahead at once, closed gate or not (`LoginRefusals`).
    func fetchClaudeIfAllowed(now start: Date,
                              proceed: @escaping @Sendable @MainActor () -> Date? = { .now }) async -> FetchOutcome {
        await openGateForNewLogin(now: start)
        guard begin(.claude, now: start) else { return FetchOutcome(problem: problems[.claude], readLogin: false) }
        defer { inFlight.remove(.claude) }
        // Taken before the read, so a login rewritten during it counts as a change next time.
        let stamp = await KeychainReader.run { KeychainReader.claudeLoginStamp() }
        guard expiredPause.allowsRead(now: start, stamp: stamp) else {
            log("fetch claude: login expired or refused, unchanged since, no read; gate open")
            return FetchOutcome(problem: problems[.claude], readLogin: false)
        }
        return FetchOutcome(problem: await readAndRequestClaude(start: start, stamp: stamp, proceed: proceed),
                            readLogin: true)
    }

    /// After a refused login has backed the gate off, a new login from Claude Code opens it at
    /// once. The stamp (attributes only: no secret, no prompt) is read only in that state.
    private func openGateForNewLogin(now: Date) async {
        guard refusals.isActive, !gates[.claude].allows(now: now), !inFlight.contains(.claude) else { return }
        let stamp = await KeychainReader.run { KeychainReader.claudeLoginStamp() }
        if refusals.openForNewLogin(stamp: stamp, gate: &gates[.claude]) {
            log("fetch claude: new login since the refusal, backoff dropped")
        }
    }

    /// The Claude attempt from the login read on, once the gate and the pause allowed it.
    private func readAndRequestClaude(start: Date, stamp: LoginStamp,
                                      proceed: @escaping @Sendable @MainActor () -> Date?) async -> FetchProblem? {
        let login = await KeychainReader.run { KeychainReader.claudeCredentials() }
        let resumed = await proceed()
        let now = max(start, resumed ?? start)
        let credentials: ClaudeCredentials
        switch login {
        case .success(let value):
            credentials = value
        case .failure(let problem):
            plan = nil
            expiredPause.clear()
            gates[.claude].recordFailure(now: now)
            return finish(.claude, problem, "no usable login", now: now)
        }
        guard resumed != nil else {
            log("fetch claude: turned off during the login read, no request")
            return problems[.claude]
        }
        plan = credentials.planLabel
        guard credentials.expiresAt > now else {
            // No request and no gate change: the next trigger reads the login again once
            // Claude Code has rewritten it (or 15 minutes on), and goes ahead with a fresh token.
            expiredPause.record(now: now, stamp: stamp)
            return finish(.claude, .tokenExpired, "token expired, no request", now: now)
        }
        expiredPause.clear()
        return await send(UsageRequests.claude(token: credentials.accessToken), for: .claude, now: now,
                          loginStamp: stamp) { data in
            try ClaudeOAuthUsage.windows(from: data, observedAt: now)
        }
    }

    /// Codex: reads Codex's login (`auth.json`, otherwise its Keychain item) and asks for the
    /// usage when the gate is open. `proceed` and a failed read work as for Claude.
    func fetchCodexIfAllowed(now start: Date,
                             proceed: @escaping @Sendable @MainActor () -> Date? = { .now }) async -> FetchOutcome {
        guard begin(.codex, now: start) else { return FetchOutcome(problem: problems[.codex], readLogin: false) }
        defer { inFlight.remove(.codex) }
        return FetchOutcome(problem: await readAndRequestCodex(start: start, proceed: proceed), readLogin: true)
    }

    /// The Codex attempt from the login read on, once the gate allowed it.
    private func readAndRequestCodex(start: Date,
                                     proceed: @escaping @Sendable @MainActor () -> Date?) async -> FetchProblem? {
        let login = await KeychainReader.run { KeychainReader.codexAuth() }
        let resumed = await proceed()
        let now = max(start, resumed ?? start)
        let auth: CodexAuth
        switch login {
        case .success(let value):
            auth = value
        case .failure(let problem):
            gates[.codex].recordFailure(now: now)
            return finish(.codex, problem, "no usable login", now: now)
        }
        guard resumed != nil else {
            log("fetch codex: turned off during the login read, no request")
            return problems[.codex]
        }
        return await send(UsageRequests.codex(auth), for: .codex, now: now) { data in
            try CodexUsage.parse(data, observedAt: now).windows
        }
    }

    /// Claude plan name from the latest login read, such as "Max 5x".
    func planLabel() -> String? {
        plan
    }

    func status(of provider: Provider) -> FetchStatus {
        FetchStatus(lastSuccess: successes[provider], nextAttempt: gates[provider].nextAttempt)
    }

    // MARK: - Private

    /// Claims the provider's attempt when its gate is open and none is running.
    private func begin(_ provider: Provider, now: Date) -> Bool {
        if inFlight.contains(provider) {
            log("fetch \(provider.rawValue): already running")
            return false
        }
        guard gates[provider].allows(now: now) else {
            log("fetch \(provider.rawValue): gate closed until \(gates[provider].nextAttempt?.formatted(.iso8601) ?? "?")")
            return false
        }
        inFlight.insert(provider)
        return true
    }

    /// Sends one request and records its outcome in the gate. 200 appends the parsed windows
    /// to the store; 429 waits for `Retry-After` (at least the gate's minimum); a refused
    /// Claude login waits for a new one (`FailedRequest`), keyed on `loginStamp`, taken before
    /// the login read, and backs off as well when that login was refused before
    /// (`LoginRefusals`); anything else backs off.
    private func send(_ request: URLRequest, for provider: Provider, now: Date, loginStamp: LoginStamp? = nil,
                      windows parse: (Data) throws -> [LimitWindow]) async -> FetchProblem? {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
        } catch {
            gates[provider].recordFailure(now: now)
            return finish(provider, .network, "network error", now: now)
        }
        guard let http = response as? HTTPURLResponse else {
            gates[provider].recordFailure(now: now)
            return finish(provider, .malformed, "not an HTTP response", now: now)
        }
        switch http.statusCode {
        case 200:
            guard let windows = try? parse(data) else {
                gates[provider].recordFailure(now: now)
                return finish(provider, .malformed, "HTTP 200, unreadable body", now: now)
            }
            if !windows.isEmpty { _ = try? store.append(windows, at: now) }
            gates[provider].recordSuccess(now: now)
            successes[provider] = now
            return finish(provider, nil, "HTTP 200, \(windows.count) windows", now: now)
        case 429:
            let retryAfter = RetryAfter.interval(http.value(forHTTPHeaderField: "Retry-After"), now: now)
            gates[provider].recordRateLimited(retryAfter: retryAfter, now: now)
            return finish(provider, .rateLimited(until: gates[provider].nextAttempt ?? now), "HTTP 429", now: now)
        case let code:
            if FailedRequest.action(forStatus: code, provider: provider) == .pauseUntilLoginChanges, let loginStamp {
                expiredPause.record(now: now, stamp: loginStamp)
                let repeated = refusals.recordRefusal(stamp: loginStamp, now: now, gate: &gates[provider])
                return finish(provider, .http(code),
                              "HTTP \(code), login refused\(repeated ? " again, backing off" : ""); waiting for a new one",
                              now: now)
            }
            gates[provider].recordFailure(now: now)
            return finish(provider, .http(code), "HTTP \(code)", now: now)
        }
    }

    /// Stores the attempt's outcome and persists the gates. Any Claude outcome but a refused
    /// login ends the run of refusals.
    private func finish(_ provider: Provider, _ problem: FetchProblem?, _ note: String, now: Date) -> FetchProblem? {
        problems[provider] = problem
        if provider == .claude, !Self.isRefusal(problem) { refusals.clear() }
        Self.save(gates, to: paths.fetchGates)
        let gate = gates[provider]
        log("fetch \(provider.rawValue): \(note); "
            + (gate.allows(now: now) ? "gate open" : "gate closed until \(gate.nextAttempt?.formatted(.iso8601) ?? "?")"))
        return problem
    }

    private static func isRefusal(_ problem: FetchProblem?) -> Bool {
        guard case .http(let code) = problem else { return false }
        return FailedRequest.action(forStatus: code, provider: .claude) == .pauseUntilLoginChanges
    }

    /// Never logs a credential, a header or a response body: only the provider and the outcome.
    private func log(_ line: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    // MARK: - Gates

    /// One gate per provider, stored as JSON.
    private struct Gates: Codable {
        var claude = FetchGate()
        var codex = FetchGate()

        subscript(provider: Provider) -> FetchGate {
            get {
                switch provider {
                case .claude: claude
                case .codex: codex
                }
            }
            set {
                switch provider {
                case .claude: claude = newValue
                case .codex: codex = newValue
                }
            }
        }
    }

    /// A missing or corrupt file starts with fresh gates. A gate closed beyond the longest
    /// backoff (saved before the 429 delay had a ceiling) opens at that limit instead.
    private static func loadGates(from url: URL, now: Date) -> Gates {
        guard let data = try? Data(contentsOf: url), var gates = try? JSONDecoder().decode(Gates.self, from: data) else {
            return Gates()
        }
        gates.claude.clamp(now: now)
        gates.codex.clamp(now: now)
        return gates
    }

    /// Best effort: if the write fails, the in-memory gates still hold until the next launch.
    private static func save(_ gates: Gates, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(gates).write(to: url, options: .atomic)
        } catch {}
    }
}

/// Keeps the token on the documented host: a redirect is not followed, and the redirect
/// response itself counts as the answer (a failed request).
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
