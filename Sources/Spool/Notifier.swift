import Foundation
import Observation
import SpoolCore
import UserNotifications

/// Delivers the 5-hour threshold notifications. Authorization is asked lazily: on the
/// first notification to deliver, or when the user turns notifications on in the settings.
@MainActor @Observable final class Notifier {
    /// True when notifications for Spool are turned off in System Settings.
    private(set) var isDenied = false

    @ObservationIgnored private let debug = ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1"
    @ObservationIgnored private let presenter = Presenter()

    /// Lets banners show while Spool is the active app (for example with the settings window
    /// in front) and reads the current authorization.
    func start() {
        center.delegate = presenter
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        let status = await center.notificationSettings().authorizationStatus
        isDenied = status == .denied
        log("notify-auth-status: \(Self.name(of: status)) (\(status.rawValue))")
    }

    /// Asks the system once; later calls return the stored answer without a prompt.
    func requestAuthorization() async -> Bool {
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
            log("notify-auth: \(granted ? "granted" : "not granted")")
        } catch {
            granted = false
            log("notify-auth: error \(error)")
        }
        await refreshAuthorization()
        return granted
    }

    /// `namesProvider`: more than one provider has data, so the subtitle says whose window it is.
    func notify(threshold: Double, window: LimitWindow, verdict: Verdict, forecastEnabled: Bool,
                namesProvider: Bool) {
        let percent = Int(threshold.rounded())
        var runsOut: Date?
        if forecastEnabled, case .runsOut(let date) = verdict { runsOut = date }
        let title = L10n.thresholdTitle(percent)
        let body = L10n.thresholdBody(resetsAt: window.resetsAt, runsOutAt: runsOut, now: .now)
        let subtitle = namesProvider ? L10n.notificationProvider(window.provider) : nil
        log("notify: \(percent)" + (subtitle.map { " subtitle: \($0)" } ?? ""))
        // One identifier per window and threshold, so a repeat replaces instead of stacking.
        let identifier = "threshold-\(window.provider.rawValue)-\(Int(window.resetsAt.timeIntervalSince1970))-\(percent)"
        Task {
            guard await isAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                log("notify-added: \(percent)")
            } catch {
                log("notify-error: \(error)")
            }
        }
    }

    // MARK: - Private

    private var center: UNUserNotificationCenter { .current() }

    private func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            isDenied = true
            return false
        @unknown default:
            return false
        }
    }

    private static func name(of status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }

    private func log(_ line: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}

/// Shows Spool's notifications as banners even while Spool is the active app.
private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
