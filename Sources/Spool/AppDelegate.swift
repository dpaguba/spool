import AppKit
import SpoolCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var settings: SettingsWindowController?
    private var watcher: FileWatcher?
    private var wakeObserver: (any NSObjectProtocol)?
    private var debugSignal: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = SpoolPaths.standard()
        let store = SampleStore(paths: paths)
        let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/spool-statusline").path
        let connector = ClaudeCodeConnector(settingsURL: ClaudeCodeConnector.standardSettingsURL(),
                                            paths: paths, helperPath: helperPath)
        let preferences = Preferences()
        let notifier = Notifier()
        notifier.start()
        let fetcher = UsageFetcher(store: store, paths: paths)
        let model = AppModel(store: store, connector: connector, preferences: preferences,
                             notifier: notifier, thresholdsURL: paths.thresholds, fetcher: fetcher)
        self.model = model

        try? store.compact(now: .now)
        model.reload()
        // Launch is an event too: enabled optional sources get a check now (through their
        // persisted gates, so a quick relaunch sends nothing) instead of 15 minutes later.
        model.checkSources()

        let settings = SettingsWindowController(model: model, preferences: preferences, notifier: notifier)
        self.settings = settings
        let panel = PanelController(model: model, openSettings: { [weak settings] in
            settings?.show()
        })
        self.panel = panel
        let statusItem = StatusItemController(model: model) { [weak panel] button in
            panel?.toggle(relativeTo: button)
        }
        self.statusItem = statusItem

        // Developer aids for live checks without clicking the menu bar.
        let environment = ProcessInfo.processInfo.environment
        if environment["SPOOL_DEBUG"] == "1" {
            runDebugActions(model, settings: settings)
            if CommandLine.arguments.contains("--open-panel"), let button = statusItem.button {
                panel.toggle(relativeTo: button)
            }
            // SIGUSR1 runs the source checks a panel open runs, so the gates can be checked live.
            signal(SIGUSR1, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            signalSource.setEventHandler { [weak model] in
                MainActor.assumeIsolated {
                    FileHandle.standardError.write(Data("debug: SIGUSR1, checking sources\n".utf8))
                    model?.checkSources()
                }
            }
            signalSource.resume()
            debugSignal = signalSource
        }

        let watcher = FileWatcher(url: paths.observations) { [weak model] in model?.reload() }
        watcher.start()
        self.watcher = watcher

        // Recompute after sleep: a reset may have passed while the lid was closed.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.reload() }
        }

        model.startTicking()
    }

    /// `--debug-action <name>` (repeatable, in order; only with `SPOOL_DEBUG=1`): runs what the
    /// settings window and its buttons run and writes the resulting state to stderr.
    /// Names: `open-settings`, `close-settings`, `connect`, `disconnect`, `repair`, `login-on`,
    /// `login-off`.
    private func runDebugActions(_ model: AppModel, settings: SettingsWindowController) {
        func log(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }
        func logConnection(_ prefix: String) {
            let status = model.connection
            log("\(prefix)connection: \(L10n.connectionTitle(status)) | "
                + L10n.connectionDetail(status, settingsPath: model.claudeSettingsPath))
            if let error = model.connectionError { log("\(prefix)connection-error: \(error)") }
        }

        let arguments = CommandLine.arguments
        let actions = arguments.indices.dropLast()
            .filter { arguments[$0] == "--debug-action" }
            .map { arguments[$0 + 1] }
        guard !actions.isEmpty else { return }
        logConnection("")
        log("launchAtLogin: \(LaunchAtLogin.statusDescription)")
        for action in actions {
            switch action {
            case "open-settings": settings.show()
            case "close-settings": settings.close()
            case "connect": model.connectClaudeCode(); logConnection("\(action) -> ")
            case "disconnect": model.disconnectClaudeCode(); logConnection("\(action) -> ")
            case "repair": model.repairClaudeCode(); logConnection("\(action) -> ")
            case "login-on", "login-off":
                do {
                    try LaunchAtLogin.set(action == "login-on")
                } catch {
                    log("\(action) -> launchAtLogin-error: \(error.localizedDescription)")
                }
                log("\(action) -> launchAtLogin: \(LaunchAtLogin.statusDescription)")
            default: log("unknown debug action: \(action)")
            }
        }
    }
}
