import Foundation
import Observation
import SpoolCore

/// Everything the menu bar and the panel show, recomputed from the stored observations
/// and the current time on every `reload()`.
@MainActor @Observable final class AppModel {
    private(set) var assessments: [Provider: [Assessment]] = [:]
    private(set) var label = MenuBarLabel(usedFraction: 0, text: .noData, isAccent: false, isWeekly: false)
    /// When data last arrived: the newest stored observation, or a later repeat of it, which
    /// the store records as the file's modification time instead of a new line.
    private(set) var lastUpdated: Date?
    private(set) var connection: ConnectionStatus
    private(set) var connectionError: String?
    /// Whether Detailed limits currently supplies a Claude window that has not reset, so Claude
    /// data keeps arriving without the status line.
    private(set) var claudeHasDetailedData = false
    /// Provider whose binding window the menu bar shows: `preferences.menuBarProvider` when both
    /// have data, otherwise whichever has data. `reload()` re-derives it.
    private(set) var displayedProvider: Provider
    /// The forecast setting the current assessments and bindings were derived with.
    private(set) var forecastEnabled: Bool
    /// The "now" of the last `reload()`, which the panel draws against.
    private(set) var evaluatedAt: Date
    /// The settings line of each enabled optional source; nil before its first check this launch.
    private(set) var sourceStates: [Provider: SourceState] = [:]
    /// Claude plan name from Claude Code's login, known after a check while Detailed limits is on.
    private(set) var planLabel: String?
    /// Whether a Codex login exists on this Mac (`KeychainReader.codexLoginExists`), as of the
    /// last `refreshCodexDetection()`.
    private(set) var codexLoginFound = false

    /// Binding window of each provider that has data.
    private var bindings: [Provider: Assessment] = [:]
    /// Samples of each provider's binding window instance, sorted, running maximum (`WindowMerge.samples`).
    private var bindingSampleSets: [Provider: [UsageSample]] = [:]

    @ObservationIgnored private let store: SampleStore
    /// The stored observations, read in full once and then only as far as they grew.
    @ObservationIgnored private var cache = ObservationCache()
    /// `stat` of the Claude Code settings file when `connection` was last read from it.
    @ObservationIgnored private var settingsStamp: FileStamp?
    @ObservationIgnored private let connector: ClaudeCodeConnector
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let notifier: Notifier?
    @ObservationIgnored private let thresholdsURL: URL?
    /// Loaded from `thresholdsURL` on first use; a missing or corrupt file starts fresh.
    @ObservationIgnored private var tracker: ThresholdTracker?
    /// Nil in snapshots: nothing is read or requested there.
    @ObservationIgnored private let fetcher: UsageFetcher?
    /// Sources with a check running, so an overlapping trigger does not start another.
    @ObservationIgnored private var checking: Set<Provider> = []
    /// Sources enabled at the last preference change, to spot one turned on or off.
    @ObservationIgnored private var enabledSources: Set<Provider> = []
    @ObservationIgnored private var detectingCodexLogin = false
    @ObservationIgnored private let debug = ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1"

    /// Threshold notifications run only with both `notifier` and `thresholdsURL`, and the
    /// optional sources only with `fetcher` (the app); snapshots pass none of them.
    init(store: SampleStore, connector: ClaudeCodeConnector, preferences: Preferences,
         notifier: Notifier? = nil, thresholdsURL: URL? = nil, fetcher: UsageFetcher? = nil,
         now: @escaping () -> Date = { .now }) {
        self.store = store
        self.connector = connector
        self.preferences = preferences
        self.notifier = notifier
        self.thresholdsURL = thresholdsURL
        self.fetcher = fetcher
        self.now = now
        // Taken before the read, so an edit during it shows as a change at the next reload.
        settingsStamp = connector.settingsStamp()
        connection = connector.status()
        displayedProvider = preferences.menuBarProvider
        forecastEnabled = preferences.forecastEnabled
        evaluatedAt = now()
        enabledSources = Set(Provider.allCases.filter { Self.isChecked($0, preferences) })
        observePreferences()
    }

    /// The Claude Code settings file, with the home folder as `~`.
    var claudeSettingsPath: String {
        (connector.settingsURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// The connection problem the panel names above its footer while it shows data: a status
    /// line that needs repair, always; one that is not connected or a settings file Spool
    /// cannot read, while Claude data is shown and Detailed limits does not stand in for the
    /// status line. Nil when there is nothing to say.
    var connectionNote: ConnectionStatus? {
        switch connection {
        case .connected: nil
        case .needsRepair: connection
        case .notConnected, .settingsUnreadable:
            providersWithData.contains(.claude) && !claudeHasDetailedData ? connection : nil
        }
    }

    /// Providers that have at least one current window, in `Provider.allCases` order.
    var providersWithData: [Provider] {
        Provider.allCases.filter { !(assessments[$0] ?? []).isEmpty }
    }

    func binding(for provider: Provider) -> Assessment? {
        bindings[provider]
    }

    func bindingSamples(for provider: Provider) -> [UsageSample] {
        bindingSampleSets[provider] ?? []
    }

    /// Every window of `provider` except its binding one: session first, then weekly, then
    /// per-model weekly windows by model name.
    func otherAssessments(for provider: Provider) -> [Assessment] {
        let bindingKind = bindings[provider]?.window.kind
        return (assessments[provider] ?? [])
            .filter { $0.window.kind != bindingKind }
            .sorted { Self.order($0.window.kind) < Self.order($1.window.kind) }
    }

    /// Recomputes everything from the stored observations and the current time. Only the bytes
    /// appended since the last reload are decoded, and the Claude Code settings file is read
    /// again only when its `stat` changed, or always with `checkConnection` (the 15-minute tick,
    /// opening the panel or the settings window).
    func reload(checkConnection: Bool = false) {
        let now = now()
        // On a read error the cache keeps what it had.
        try? cache.update(from: store)
        let observations = cache.observations.compactMap(visible)

        var grouped: [Provider: [Assessment]] = [:]
        var samplesByWindow: [LimitWindow: [UsageSample]] = [:]
        for window in WindowMerge.current(from: observations) {
            let samples = WindowMerge.samples(for: window, in: observations)
            samplesByWindow[window] = samples
            let verdict = PaceForecaster.verdict(for: window, samples: samples, now: now)
            grouped[window.provider, default: []].append(Assessment(window: window, verdict: verdict))
        }

        let withData = Provider.allCases.filter { !(grouped[$0] ?? []).isEmpty }
        let preferred = preferences.menuBarProvider
        let provider = withData.contains(preferred) || withData.isEmpty ? preferred : withData[0]
        let forecast = preferences.forecastEnabled
        var newBindings: [Provider: Assessment] = [:]
        var newSampleSets: [Provider: [UsageSample]] = [:]
        for p in withData {
            guard let picked = BindingWindow.pick(grouped[p] ?? [], forecastEnabled: forecast, now: now) else { continue }
            newBindings[p] = picked
            newSampleSets[p] = samplesByWindow[picked.window] ?? []
        }
        let newLabel = MenuBarLabelBuilder.make(binding: newBindings[provider], forecastEnabled: forecast, now: now)
        let newUpdated = observations.map(\.t).max().map { newest in max(newest, store.lastModified() ?? newest) }
        let newDetailed = observations.contains { observation in
            observation.windows.contains { $0.provider == .claude && $0.source == .oauth && !$0.isExpired(at: now) }
        }

        // Assign only real changes so observers (and the SPOOL_DEBUG label line) fire on change.
        if assessments != grouped { assessments = grouped }
        if displayedProvider != provider { displayedProvider = provider }
        if forecastEnabled != forecast { forecastEnabled = forecast }
        if bindings != newBindings { bindings = newBindings }
        if bindingSampleSets != newSampleSets { bindingSampleSets = newSampleSets }
        if label != newLabel { label = newLabel }
        if lastUpdated != newUpdated {
            lastUpdated = newUpdated
            if debug, let newUpdated {
                FileHandle.standardError.write(Data("updated: \(newUpdated.formatted(.iso8601))\n".utf8))
            }
        }
        refreshConnection(force: checkConnection)
        if claudeHasDetailedData != newDetailed { claudeHasDetailedData = newDetailed }
        // Always moves: the open panel redraws its "now" marker and verdict times against it.
        evaluatedAt = now

        evaluateThresholds(grouped, now: now)
    }

    func tick() async {
        try? store.compact(now: now())
        reload(checkConnection: true)
        checkSources()
    }

    /// Starts a check of every enabled optional source, each through its gate, without waiting
    /// for it: a Keychain prompt can hold the Claude check for as long as it is open. New
    /// windows land in the store, and the file watcher redraws.
    func checkSources() {
        for provider in Provider.allCases where Self.isChecked(provider, preferences) {
            Task { await check(provider) }
        }
    }

    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while true {
                // The one recurring timer in Spool: every 15 minutes recompute from the stored
                // data and the current time, so an idle forecast drifts later and a passed reset
                // flips to 100%.
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func connectClaudeCode() {
        perform { try connector.connect(now: now()) }
    }

    func disconnectClaudeCode() {
        perform { try connector.disconnect(now: now()) }
    }

    func repairClaudeCode() {
        perform { try connector.repair(now: now()) }
    }

    /// Looks again whether a Codex login exists, off the main thread: a usable `auth.json`, or
    /// Codex's Keychain item by its attributes only (no secret read, no prompt). The settings
    /// window calls this when it shows; it is too slow for every `reload()`.
    func refreshCodexDetection() {
        guard fetcher != nil, !detectingCodexLogin else { return }
        detectingCodexLogin = true
        Task {
            let found = await KeychainReader.run { KeychainReader.codexLoginExists() }
            detectingCodexLogin = false
            if codexLoginFound != found { codexLoginFound = found }
            if debug { FileHandle.standardError.write(Data("codex-login: \(found ? "found" : "not found")\n".utf8)) }
        }
    }

    /// The settings line of an optional source, or nil before its first check this launch.
    /// A Codex login that exists but could not be read is not reported as missing.
    func sourceStatusText(_ provider: Provider) -> String? {
        guard let state = sourceStates[provider] else { return nil }
        if provider == .codex, state == .failed(.noCredentials), codexLoginFound { return L10n.codexLoginUnreadable }
        return L10n.sourceStatus(state, provider: provider, now: evaluatedAt)
    }

    /// Snapshots only: sets what live checks would have found.
    func showFixtureSources(_ states: [Provider: SourceState], planLabel: String?, codexLoginFound: Bool) {
        sourceStates = states
        self.planLabel = planLabel
        self.codexLoginFound = codexLoginFound
    }

    // MARK: - Private

    /// Whether the optional source of `provider` is on: Detailed limits for Claude, the Codex
    /// toggle for Codex.
    private static func isChecked(_ provider: Provider, _ preferences: Preferences) -> Bool {
        switch provider {
        case .claude: preferences.detailedLimitsEnabled
        case .codex: preferences.codexEnabled
        }
    }

    /// The observation without the windows of sources that are off; nil when none is left.
    private func visible(_ observation: UsageObservation) -> UsageObservation? {
        let windows = observation.windows.filter { window in
            switch window.source {
            case .statusline: true
            case .oauth: preferences.detailedLimitsEnabled
            case .codexAPI: preferences.codexEnabled
            }
        }
        return windows.isEmpty ? nil : UsageObservation(t: observation.t, windows: windows)
    }

    private func check(_ provider: Provider) async {
        guard let fetcher, Self.isChecked(provider, preferences), !checking.contains(provider) else { return }
        checking.insert(provider)
        defer { checking.remove(provider) }
        if sourceStates[provider] == nil { sourceStates[provider] = .checking }
        let outcome: FetchOutcome
        switch provider {
        case .claude: outcome = await fetcher.fetchClaudeIfAllowed(now: now(), proceed: proceed(.claude))
        case .codex: outcome = await fetcher.fetchCodexIfAllowed(now: now(), proceed: proceed(.codex))
        }
        let problem = outcome.problem
        let status = await fetcher.status(of: provider)
        let plan = provider == .claude ? await fetcher.planLabel() : nil
        // Only after a login read of this check: with the gate closed the problem is the cached
        // one, and probing again on every panel open would learn nothing new.
        if provider == .codex, outcome.readLogin, problem == .noCredentials {
            // The same predicate as the line under the toggle, so the two never disagree.
            codexLoginFound = await KeychainReader.run { KeychainReader.codexLoginExists() }
            if debug {
                FileHandle.standardError.write(Data("codex-login: \(codexLoginFound ? "found" : "not found") after a read\n".utf8))
            }
        }
        // Turned off while the check ran: keep nothing from it.
        guard Self.isChecked(provider, preferences) else { return }
        sourceStates[provider] = SourceState(problem: problem, status: status, now: now())
        if provider == .claude { planLabel = plan }
        if debug {
            FileHandle.standardError.write(Data("source \(provider.rawValue): \(sourceStatusText(provider) ?? "none")\n".utf8))
        }
    }

    /// Asked by the fetcher after a login read, which can wait on a Keychain prompt: the current
    /// time while the source is still on, nil once it was turned off.
    private func proceed(_ provider: Provider) -> @Sendable @MainActor () -> Date? {
        { [weak self] in
            guard let self, Self.isChecked(provider, self.preferences) else { return nil }
            return self.now()
        }
    }

    /// A source turned on gets its first check right away (macOS may ask for Keychain access
    /// then); one turned off drops its status, and Detailed limits its plan name.
    private func sourcesDidChange() {
        let enabled = Set(Provider.allCases.filter { Self.isChecked($0, preferences) })
        for provider in enabledSources.subtracting(enabled) {
            sourceStates[provider] = nil
            if provider == .claude { planLabel = nil }
        }
        let added = enabled.subtracting(enabledSources)
        if enabled.contains(.codex) != enabledSources.contains(.codex) { refreshCodexDetection() }
        enabledSources = enabled
        for provider in Provider.allCases where added.contains(provider) {
            Task { await check(provider) }
        }
    }

    private static func order(_ kind: WindowKind) -> (Int, String) {
        switch kind {
        case .session: (0, "")
        case .weekly: (1, "")
        case .weeklyModel(let name): (2, name)
        }
    }

    /// Runs every provider's current 5-hour window through the tracker, persists the
    /// tracker after any change, and notifies for newly crossed thresholds when enabled. The
    /// tracker advances even while notifications are off, so turning them on later does not
    /// replay crossings that already happened.
    private func evaluateThresholds(_ grouped: [Provider: [Assessment]], now: Date) {
        guard let notifier, let thresholdsURL else { return }
        var tracker = self.tracker ?? Self.loadTracker(from: thresholdsURL)
        let before = tracker
        var crossed: [(threshold: Double, assessment: Assessment)] = []
        for provider in Provider.allCases {
            for item in grouped[provider] ?? [] where item.window.kind == .session && !item.window.isExpired(at: now) {
                if let threshold = tracker.evaluate(item.window, thresholds: preferences.thresholds, now: now) {
                    crossed.append((threshold, item))
                }
            }
        }
        self.tracker = tracker
        if tracker != before { Self.save(tracker, to: thresholdsURL) }

        guard preferences.notificationsEnabled else { return }
        let namesProvider = Provider.allCases.filter { !(grouped[$0] ?? []).isEmpty }.count > 1
        for (threshold, item) in crossed {
            notifier.notify(threshold: threshold, window: item.window, verdict: item.verdict,
                            forecastEnabled: preferences.forecastEnabled, namesProvider: namesProvider)
        }
    }

    private static func loadTracker(from url: URL) -> ThresholdTracker {
        guard let data = try? Data(contentsOf: url),
              let tracker = try? JSONDecoder().decode(ThresholdTracker.self, from: data) else { return ThresholdTracker() }
        return tracker
    }

    /// Best effort: if the write fails, the in-memory tracker still dedupes until the next launch.
    private static func save(_ tracker: ThresholdTracker, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(tracker).write(to: url, options: .atomic)
        } catch {}
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            connectionError = nil
        } catch {
            connectionError = L10n.errorText(error)
        }
        refreshConnection(force: true)
    }

    /// Reads the connection from the Claude Code settings file when `force`, or when its `stat`
    /// changed since the last read: a watcher event or a wake need not parse it again.
    private func refreshConnection(force: Bool) {
        let stamp = connector.settingsStamp()
        guard force || stamp != settingsStamp else { return }
        settingsStamp = stamp
        let status = connector.status()
        if connection != status { connection = status }
    }

    /// Reloads whenever a preference that shapes the label or the shown sources changes.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.forecastEnabled
            _ = preferences.menuBarProvider
            _ = preferences.detailedLimitsEnabled
            _ = preferences.codexEnabled
        } onChange: { [weak self] in
            // onChange runs before the new value is stored; hop so reload sees it.
            Task { @MainActor in
                guard let self else { return }
                self.sourcesDidChange()
                self.reload()
                self.observePreferences()
            }
        }
    }
}

/// The settings line of one optional source.
enum SourceState: Equatable {
    /// The first check of this launch is running.
    case checking
    case checked(Date)
    /// Nothing learned this launch, and the gate is closed until then.
    case waiting(until: Date)
    case failed(FetchProblem)

    /// `problem` is the latest attempt's. Nil when there is nothing to say (no attempt, gate open).
    init?(problem: FetchProblem?, status: FetchStatus, now: Date) {
        if let problem {
            self = .failed(problem)
        } else if let success = status.lastSuccess {
            self = .checked(success)
        } else if let next = status.nextAttempt, next > now {
            self = .waiting(until: next)
        } else {
            return nil
        }
    }
}
