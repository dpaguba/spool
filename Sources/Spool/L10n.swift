import Foundation
import SpoolCore
import SwiftUI

/// Every user-visible string. Values live in `Contents/Resources/<lang>.lproj/Localizable.strings`
/// of the app bundle, copied there by `scripts/build-app.sh`.
enum L10n {
    /// "until 15:40" / "до 15:40"; `time` is already formatted for the user's locale.
    static func until(_ time: String) -> String {
        format("label.until", time)
    }

    /// Marker shown before the menu bar text when the binding limit is weekly.
    static var weeklyMarker: String { string("label.weeklyMarker") }

    /// Accessibility value of the menu bar item while there is no data.
    static var noData: String { string("label.noData") }

    /// Accessibility description of the menu bar item.
    static var statusItemDescription: String { string("statusItem.accessibilityDescription") }

    /// Text for an error thrown while connecting, disconnecting or repairing Claude Code.
    static func errorText(_ error: any Error) -> String {
        guard let error = error as? SpoolError else { return error.localizedDescription }
        switch error {
        case .malformedJSON: return string("error.malformedJSON")
        case .notAnObject: return string("error.notAnObject")
        case .missingField(let name): return format("error.missingField", name)
        case .io(let detail): return format("error.io", detail)
        case .duplicateKey(let key): return format("error.duplicateKey", key)
        case .duplicateKeyInEntry(let entry, let key): return format("error.duplicateKeyInEntry", entry, key)
        }
    }

    // MARK: - Panel

    /// "5-hour window", "Week", "Week, Fable".
    static func windowName(_ kind: WindowKind) -> String {
        switch kind {
        case .session: string("panel.window.session")
        case .weekly: string("panel.window.weekly")
        case .weeklyModel(let name): format("panel.window.weeklyModel", name)
        }
    }

    /// Segment title of a provider in the panel.
    static func providerName(_ provider: Provider) -> String {
        switch provider {
        case .claude: string("panel.provider.claude")
        case .codex: string("panel.provider.codex")
        }
    }

    /// "runs out at 15:40" on the same calendar day, otherwise "runs out Thu 15:40".
    static func runsOut(at date: Date, now: Date) -> String {
        isToday(date, now: now)
            ? format("panel.runsOutAt", clock(date, now: now))
            : format("panel.runsOutOn", clock(date, now: now))
    }

    /// "resets at 16:10" on the same calendar day, otherwise "resets Mon 09:00".
    static func resets(at date: Date, now: Date) -> String {
        isToday(date, now: now)
            ? format("panel.resetsAt", clock(date, now: now))
            : format("panel.resetsOn", clock(date, now: now))
    }

    /// "in 1:47" around a live countdown. The countdown is a `Text` so the system keeps it current.
    static func resetsIn(_ countdown: Text) -> Text {
        Text("panel.resetsIn \(countdown)", bundle: .main)
    }

    /// Verdict of a window that has enough budget: "enough".
    static var enough: String { string("panel.enough") }

    /// Verdict of the binding window that has enough budget, with the projected reserve at reset.
    static func enough(reserve percent: Int) -> String {
        format("panel.enoughWithReserve", percent)
    }

    /// Verdict of a window with nothing left.
    static var limitReached: String { string("panel.limitReached") }

    /// Chart axis label at the current time.
    static var chartNow: String { string("panel.chart.now") }

    /// Footer: "Updated 14:23", or "Updated Mon 14:23" when not today.
    static func updated(_ date: Date, now: Date) -> String {
        format("panel.updated", clock(date, now: now))
    }

    /// Footer with the plan name from Detailed limits: "Updated 14:23 · Max 5x".
    static func updated(_ date: Date, now: Date, plan: String) -> String {
        format("panel.updatedWithPlan", clock(date, now: now), plan)
    }

    static var settingsMenuItem: String { string("panel.menu.settings") }
    static var quitMenuItem: String { string("panel.menu.quit") }
    /// Accessibility label of the gear button.
    static var optionsMenu: String { string("panel.menu.options") }

    static var notConnectedTitle: String { string("panel.empty.notConnected.title") }
    static var notConnectedBody: String { string("panel.empty.notConnected.body") }
    static var connectClaudeCode: String { string("panel.empty.connect") }
    static var waitingTitle: String { string("panel.empty.waiting.title") }
    static var waitingBody: String { string("panel.empty.waiting.body") }
    static var needsRepairTitle: String { string("panel.empty.needsRepair.title") }
    static var needsRepairBody: String { string("panel.empty.needsRepair.body") }
    static var unreadableTitle: String { string("panel.empty.unreadable.title") }
    /// `settingsPath` is the Claude Code settings file.
    static func unreadableBody(settingsPath: String) -> String { format("panel.empty.unreadable.body", settingsPath) }
    /// Button that opens Spool's settings window.
    static var openSettings: String { string("panel.openSettings") }

    /// The one line above the panel footer for a status line that does not feed Spool.
    static func connectionNote(_ status: ConnectionStatus) -> String {
        switch status {
        case .needsRepair: string("panel.note.needsRepair")
        case .settingsUnreadable: string("panel.note.unreadable")
        case .notConnected, .connected: string("panel.note.notConnected")
        }
    }

    // MARK: - Settings

    static var settingsTitle: String { string("settings.title") }

    static var claudeCodeHeader: String { string("settings.claudeCode.header") }

    /// Short state of the Claude Code status line: "Connected", "Not connected", ...
    static func connectionTitle(_ status: ConnectionStatus) -> String {
        switch status {
        case .connected: string("settings.claudeCode.connected")
        case .notConnected: string("settings.claudeCode.notConnected")
        case .needsRepair: string("settings.claudeCode.needsRepair")
        case .settingsUnreadable: string("settings.claudeCode.unreadable")
        }
    }

    /// One sentence under the state; `settingsPath` is the Claude Code settings file.
    static func connectionDetail(_ status: ConnectionStatus, settingsPath: String) -> String {
        switch status {
        case .connected: string("settings.claudeCode.connected.detail")
        case .notConnected: format("settings.claudeCode.notConnected.detail", settingsPath)
        case .needsRepair(let command): format("settings.claudeCode.needsRepair.detail", command)
        case .settingsUnreadable: format("settings.claudeCode.unreadable.detail", settingsPath)
        }
    }

    static var connect: String { string("settings.claudeCode.connect") }
    static var disconnect: String { string("settings.claudeCode.disconnect") }
    static var repair: String { string("settings.claudeCode.repair") }

    static var displayHeader: String { string("settings.display.header") }
    static var forecastToggle: String { string("settings.forecast") }
    static var forecastDetail: String { string("settings.forecast.detail") }
    static var menuBarProvider: String { string("settings.menuBarProvider") }

    static var sourcesHeader: String { string("settings.sources.header") }
    static var detailedLimitsToggle: String { string("settings.detailedLimits") }
    /// What Detailed limits adds, and the risk it carries.
    static var detailedLimitsRisk: String { string("settings.detailedLimits.detail") }
    static var codexToggle: String { string("settings.codex") }
    static var codexDetail: String { string("settings.codex.detail") }

    /// The confirmation shown after Detailed limits is switched on, before anything is read.
    static var detailedLimitsConfirmTitle: String { string("settings.detailedLimits.confirm.title") }
    static var detailedLimitsConfirmDetail: String { string("settings.detailedLimits.confirm.detail") }
    static var enable: String { string("settings.detailedLimits.enable") }
    static var cancel: String { string("settings.detailedLimits.cancel") }

    /// Under the Codex toggle while it is off: whether a Codex login exists on this Mac.
    static func codexLogin(found: Bool) -> String {
        found ? string("settings.codex.found") : string("settings.codex.noLogin")
    }

    /// The Codex login exists (file or Keychain item) but Spool could not read a usable one.
    static var codexLoginUnreadable: String { string("settings.codex.unreadable") }

    /// Second line under the Codex toggle: a Keychain login may bring a macOS prompt.
    static var codexKeychainNote: String { string("settings.codex.keychainNote") }

    /// Settings line of an optional source: "Last checked 14:23", "Rate limited until 15:10", ...
    static func sourceStatus(_ state: SourceState, provider: Provider, now: Date) -> String {
        switch state {
        case .checking: return string("settings.source.checking")
        case .checked(let date): return format("settings.source.lastChecked", clock(date, now: now))
        case .waiting(let date): return format("settings.source.nextCheck", clock(date, now: now))
        case .failed(let problem):
            switch problem {
            case .noCredentials:
                return provider == .claude ? string("settings.detailedLimits.noLogin") : string("settings.codex.noLogin")
            case .tokenExpired: return string("settings.detailedLimits.paused")
            case .rateLimited(let until): return format("settings.source.rateLimited", clock(until, now: now))
            case .http(let code): return format("settings.source.httpFailed", code)
            case .network: return string("settings.source.networkFailed")
            case .malformed: return string("settings.source.malformed")
            }
        }
    }

    static var notificationsHeader: String { string("settings.notifications.header") }
    static var notificationsToggle: String { string("settings.notifications") }
    static var notificationsDetail: String { string("settings.notifications.detail") }
    static func firstThreshold(_ percent: Int) -> String { format("settings.notifications.first", percent) }
    static func secondThreshold(_ percent: Int) -> String { format("settings.notifications.second", percent) }
    static var notificationsDenied: String { string("settings.notifications.denied") }

    static var launchAtLoginToggle: String { string("settings.launchAtLogin") }
    static var launchAtLoginApproval: String { string("settings.launchAtLogin.approval") }
    static func launchAtLoginFailed(_ detail: String) -> String { format("settings.launchAtLogin.failed", detail) }

    // MARK: - Notifications

    /// Notification subtitle naming the provider when more than one has data.
    static func notificationProvider(_ provider: Provider) -> String {
        switch provider {
        case .claude: string("notification.provider.claude")
        case .codex: string("notification.provider.codex")
        }
    }

    /// "Half of your 5-hour window is used" at 50, otherwise "90% of your 5-hour window is used".
    static func thresholdTitle(_ percent: Int) -> String {
        percent == 50 ? string("notification.title.half") : format("notification.title.percent", Int32(percent))
    }

    /// "Resets at 16:10." plus " At this pace it runs out at 15:40." when `runsOutAt` is given;
    /// each time carries a weekday when it is not today.
    static func thresholdBody(resetsAt: Date, runsOutAt: Date?, now: Date) -> String {
        var body = isToday(resetsAt, now: now)
            ? format("notification.body.resetsAt", clock(resetsAt, now: now))
            : format("notification.body.resetsOn", clock(resetsAt, now: now))
        if let runsOutAt {
            body += isToday(runsOutAt, now: now)
                ? format("notification.body.runsOutAt", clock(runsOutAt, now: now))
                : format("notification.body.runsOutOn", clock(runsOutAt, now: now))
        }
        return body
    }

    /// Time only when `date` is on the same calendar day as `now`, otherwise day and time.
    static func clock(_ date: Date, now: Date) -> String {
        StatusItemContent.runOutText(date, now: now, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
    }

    private static func isToday(_ date: Date, now: Date) -> Bool {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
    }

    // MARK: - Lookup

    private static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: string(key), locale: Locale.autoupdatingCurrent, arguments: arguments)
    }
}
