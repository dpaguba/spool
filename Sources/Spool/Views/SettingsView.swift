import AppKit
import SpoolCore
import SwiftUI

/// The settings window's content, in the native grouped form style.
struct SettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    let notifier: Notifier
    /// When false (snapshots), nothing reads or changes system state: the launch-at-login
    /// toggle shows `false` and the view never refreshes itself.
    let live: Bool
    /// The tallest the view may be (the screen's visible height less the title bar and a
    /// margin); a taller form scrolls inside it.
    let maxHeight: CGFloat

    @State private var launchAtLogin: Bool
    @State private var launchAtLoginNote: String?
    /// Detailed limits was switched on and waits for Enable; nothing is read before that.
    @State private var confirmingDetailedLimits: Bool

    static let width: CGFloat = 460

    /// `confirmingDetailedLimits` is for snapshots of the confirmation.
    init(model: AppModel, preferences: Preferences, notifier: Notifier, live: Bool = true,
         maxHeight: CGFloat = .infinity, confirmingDetailedLimits: Bool = false) {
        self.model = model
        self.preferences = preferences
        self.notifier = notifier
        self.live = live
        self.maxHeight = maxHeight
        _launchAtLogin = State(initialValue: live && LaunchAtLogin.isEnabled)
        _launchAtLoginNote = State(initialValue: live && LaunchAtLogin.requiresApproval ? L10n.launchAtLoginApproval : nil)
        _confirmingDetailedLimits = State(initialValue: confirmingDetailedLimits)
    }

    var body: some View {
        FittedHeight(maxHeight: maxHeight) {
            form
        }
        .frame(width: Self.width)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: the login item or notification permission may have changed.
            guard live else { return }
            refreshLaunchAtLogin()
            Task { await notifier.refreshAuthorization() }
        }
    }

    private var form: some View {
        Form {
            claudeCodeSection
            displaySection
            sourcesSection
            notificationsSection
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    Text(L10n.launchAtLoginToggle)
                    if let launchAtLoginNote { Text(launchAtLoginNote) }
                }
            }
        }
        .formStyle(.grouped)
        // Scrolls only when `maxHeight` cuts the form short; content that fits does not move.
        .scrollBounceBehavior(.basedOnSize)
        .monospacedDigit()
    }

    // MARK: - Sections

    private var claudeCodeSection: some View {
        Section(L10n.claudeCodeHeader) {
            let status = model.connection
            LabeledContent {
                HStack(spacing: 8) {
                    switch status {
                    case .notConnected:
                        Button(L10n.connect) { model.connectClaudeCode() }
                    case .connected:
                        Button(L10n.disconnect) { model.disconnectClaudeCode() }
                    case .needsRepair:
                        Button(L10n.disconnect) { model.disconnectClaudeCode() }
                        Button(L10n.repair) { model.repairClaudeCode() }
                    case .settingsUnreadable:
                        // Spool changes nothing in a file it cannot read.
                        EmptyView()
                    }
                }
                .fixedSize()
            } label: {
                Text(L10n.connectionTitle(status))
                Text(L10n.connectionDetail(status, settingsPath: model.claudeSettingsPath))
            }
            if let error = model.connectionError {
                Text(error)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displaySection: some View {
        Section(L10n.displayHeader) {
            Toggle(isOn: $preferences.forecastEnabled) {
                Text(L10n.forecastToggle)
                Text(L10n.forecastDetail)
            }
            if model.providersWithData.count > 1 {
                Picker(L10n.menuBarProvider, selection: $preferences.menuBarProvider) {
                    ForEach(Provider.allCases, id: \.self) { provider in
                        Text(L10n.providerName(provider)).tag(provider)
                    }
                }
            }
        }
    }

    private var sourcesSection: some View {
        Section(L10n.sourcesHeader) {
            Toggle(isOn: Binding(get: { preferences.detailedLimitsEnabled || confirmingDetailedLimits },
                                 set: setDetailedLimits)) {
                Text(L10n.detailedLimitsToggle)
                Text(L10n.detailedLimitsRisk)
            }
            if confirmingDetailedLimits {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(L10n.cancel) { confirmingDetailedLimits = false }
                        Button(L10n.enable) {
                            // The only place that turns Detailed limits on; the model then
                            // runs the first check (macOS may ask for Keychain access).
                            confirmingDetailedLimits = false
                            preferences.detailedLimitsEnabled = true
                        }
                    }
                    .fixedSize()
                } label: {
                    Text(L10n.detailedLimitsConfirmTitle)
                    Text(L10n.detailedLimitsConfirmDetail)
                }
            } else if preferences.detailedLimitsEnabled, let line = model.sourceStatusText(.claude) {
                Text(line)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $preferences.codexEnabled) {
                Text(L10n.codexToggle)
                // One subtitle with two lines: a third label text gets a smaller style.
                Text(verbatim: L10n.codexDetail + "\n" + L10n.codexKeychainNote)
            }
            Text(preferences.codexEnabled
                 ? model.sourceStatusText(.codex) ?? L10n.codexLogin(found: model.codexLoginFound)
                 : L10n.codexLogin(found: model.codexLoginFound))
                .foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section(L10n.notificationsHeader) {
            Toggle(isOn: Binding(get: { preferences.notificationsEnabled }, set: setNotifications)) {
                Text(L10n.notificationsToggle)
                Text(L10n.notificationsDetail)
            }
            let (first, second) = ThresholdSteps.pair(preferences.thresholds)
            Group {
                Stepper(value: Binding(get: { first }, set: { preferences.thresholds = [$0, second] }),
                        in: ThresholdSteps.lowest...(second - ThresholdSteps.step), step: ThresholdSteps.step) {
                    Text(L10n.firstThreshold(Int(first)))
                }
                Stepper(value: Binding(get: { second }, set: { preferences.thresholds = [first, $0] }),
                        in: (first + ThresholdSteps.step)...ThresholdSteps.highest, step: ThresholdSteps.step) {
                    Text(L10n.secondThreshold(Int(second)))
                }
            }
            .disabled(!preferences.notificationsEnabled)
            if notifier.isDenied {
                Text(L10n.notificationsDenied)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    /// Switching on only asks for confirmation; switching off (or cancelling) takes effect at once.
    private func setDetailedLimits(_ on: Bool) {
        if on {
            if !preferences.detailedLimitsEnabled { confirmingDetailedLimits = true }
        } else {
            confirmingDetailedLimits = false
            preferences.detailedLimitsEnabled = false
        }
    }

    private func setNotifications(_ enabled: Bool) {
        preferences.notificationsEnabled = enabled
        guard enabled, live else { return }
        Task { _ = await notifier.requestAuthorization() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard live else { return }
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLoginNote = nil
        } catch {
            launchAtLoginNote = L10n.launchAtLoginFailed(error.localizedDescription)
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
        if LaunchAtLogin.requiresApproval {
            launchAtLoginNote = L10n.launchAtLoginApproval
        } else if launchAtLoginNote == L10n.launchAtLoginApproval {
            launchAtLoginNote = nil
        }
    }
}

/// Sizes its one subview to the subview's ideal height, rounded up to a whole point and at
/// most `maxHeight`, at any proposal, and lets it fill that height. The window then follows
/// the form's content (the hosting view's min and max size are this size), and no sliver of
/// window background shows below the form when its height is fractional.
private struct FittedHeight: Layout {
    var maxHeight: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height.rounded(.up), maxHeight.rounded(.down)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The two notification thresholds as the steppers edit them: 5 % steps from 5 to 95, the
/// first always at least one step below the second.
enum ThresholdSteps {
    static let step: Double = 5
    static let lowest: Double = 5
    static let highest: Double = 95

    /// The stored thresholds snapped to steps and clamped so they never cross.
    static func pair(_ thresholds: [Double]) -> (Double, Double) {
        func snap(_ value: Double) -> Double { (value / step).rounded() * step }
        let first = min(max(snap(thresholds.first ?? 50), lowest), highest - step)
        let second = min(max(snap(thresholds.dropFirst().first ?? 90), first + step), highest)
        return (first, second)
    }
}
