import Foundation
import Observation
import SpoolCore

/// User settings, persisted in `UserDefaults`. Every property writes through on change.
@MainActor @Observable final class Preferences {
    var forecastEnabled: Bool { didSet { defaults.set(forecastEnabled, forKey: Key.forecastEnabled) } }
    var detailedLimitsEnabled: Bool { didSet { defaults.set(detailedLimitsEnabled, forKey: Key.detailedLimitsEnabled) } }
    var codexEnabled: Bool { didSet { defaults.set(codexEnabled, forKey: Key.codexEnabled) } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }
    /// Used-percent thresholds for notifications, ascending.
    var thresholds: [Double] { didSet { defaults.set(thresholds, forKey: Key.thresholds) } }
    /// Provider the menu bar follows when both have data.
    var menuBarProvider: Provider { didSet { defaults.set(menuBarProvider.rawValue, forKey: Key.menuBarProvider) } }
    // Launch at login is not stored here: `LaunchAtLogin` asks the system, which the user can
    // also change in System Settings.

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        forecastEnabled = defaults.object(forKey: Key.forecastEnabled) as? Bool ?? true
        detailedLimitsEnabled = defaults.object(forKey: Key.detailedLimitsEnabled) as? Bool ?? false
        codexEnabled = defaults.object(forKey: Key.codexEnabled) as? Bool ?? false
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        thresholds = defaults.array(forKey: Key.thresholds) as? [Double] ?? [50.0, 90.0]
        menuBarProvider = defaults.string(forKey: Key.menuBarProvider).flatMap(Provider.init(rawValue:)) ?? .claude
    }

    private enum Key {
        static let forecastEnabled = "forecastEnabled"
        static let detailedLimitsEnabled = "detailedLimitsEnabled"
        static let codexEnabled = "codexEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let thresholds = "thresholds"
        static let menuBarProvider = "menuBarProvider"
    }
}
