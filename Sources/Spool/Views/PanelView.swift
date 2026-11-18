import AppKit
import SpoolCore
import SwiftUI

/// The panel under the menu bar item: the binding window on top, the other windows below,
/// and a footer. With the forecast on the top block is a chart, with it off a large ring.
struct PanelView: View {
    let model: AppModel
    let openSettings: @MainActor () -> Void
    let quit: @MainActor () -> Void
    /// When false (snapshots), the countdown is frozen at `model.evaluatedAt`.
    let liveClock: Bool

    /// The provider shown here. Starts from the menu bar's provider each time the panel opens
    /// and never writes back.
    @State private var selection: Provider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel,
         openSettings: @escaping @MainActor () -> Void = {},
         quit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
         liveClock: Bool = true) {
        self.model = model
        self.openSettings = openSettings
        self.quit = quit
        self.liveClock = liveClock
        _selection = State(initialValue: model.displayedProvider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let providers = model.providersWithData
            if providers.isEmpty {
                EmptyStateView(connection: model.connection, settingsPath: model.claudeSettingsPath,
                               error: model.connectionError,
                               connect: { model.connectClaudeCode() },
                               repair: { model.repairClaudeCode() },
                               openSettings: openSettings)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            } else {
                if providers.count > 1 {
                    providerPicker(providers)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                }
                providerContent(provider, topPadding: providers.count > 1 ? 6 : 12)
                    .id(provider)
                    .transition(.opacity)
                if let note = model.connectionNote {
                    Hairline()
                    ConnectionNote(status: note, error: model.connectionError,
                                   connect: { model.connectClaudeCode() },
                                   repair: { model.repairClaudeCode() },
                                   openSettings: openSettings)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            Hairline()
            footer
        }
        .frame(width: 300)
        .monospacedDigit()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
    }

    // MARK: - Sections

    private var now: Date { model.evaluatedAt }

    /// The selection while it has data, otherwise the menu bar's provider.
    private var provider: Provider {
        model.providersWithData.contains(selection) ? selection : model.displayedProvider
    }

    private func providerPicker(_ providers: [Provider]) -> some View {
        ProviderPicker(providers: providers, selection: $selection)
    }

    @ViewBuilder
    private func providerContent(_ provider: Provider, topPadding: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let binding = model.binding(for: provider) {
                topBlock(binding, samples: model.bindingSamples(for: provider))
                    .padding(.horizontal, 14)
                    .padding(.top, topPadding)
                    .padding(.bottom, 12)
            }
            let others = model.otherAssessments(for: provider)
            if !others.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: model.forecastEnabled ? 10 : 8) {
                    ForEach(others, id: \.window.kind) { assessment in
                        WindowRow(assessment: assessment, forecastEnabled: model.forecastEnabled, now: now)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func topBlock(_ binding: Assessment, samples: [UsageSample]) -> some View {
        let window = binding.window
        let used = window.displayedUsedPercent(at: now)
        return VStack(alignment: .leading, spacing: 0) {
            Text(L10n.windowName(window.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if model.forecastEnabled {
                HStack(alignment: .firstTextBaseline) {
                    BigPercent(value: used)
                    Spacer(minLength: 8)
                    if let verdict = PanelText.topVerdict(binding, now: now) {
                        Text(verdict.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(verdict.isAccent ? AnyShapeStyle(Theme.accentColor) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)

                if !window.isExpired(at: now) {
                    ForecastChartView(window: window, samples: samples, verdict: binding.verdict, now: now)
                        .padding(.top, 2)
                }
            } else {
                HStack(spacing: 14) {
                    RingView(fraction: Double(used) / 100)
                    VStack(alignment: .leading, spacing: 1) {
                        BigPercent(value: used)
                        if !window.isExpired(at: now) {
                            // Reset and countdown on separate lines, so neither truncates in
                            // any language.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.resets(at: window.resetsAt, now: now))
                                if let countdown = countdown(to: window.resetsAt) {
                                    L10n.resetsIn(countdown)
                                }
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Hours and minutes to `reset` ("1:47"), kept current by the system once a minute; nil
    /// when the reset is a day or more away. Snapshots freeze it at `now`.
    private func countdown(to reset: Date) -> Text? {
        guard reset.timeIntervalSince(now) < 86_400 else { return nil }
        return liveClock
            ? Text(.durationOffset(to: reset), format: CountdownFormat())
            : Text(verbatim: CountdownFormat().format(.seconds(now.timeIntervalSince(reset))))
    }

    private var footer: some View {
        // The plan name comes from Detailed limits, so it shows only under Claude.
        let plan = provider == .claude ? model.planLabel : nil
        return HStack(alignment: .center) {
            if let updated = model.lastUpdated {
                Text(plan.map { L10n.updated(updated, now: now, plan: $0) } ?? L10n.updated(updated, now: now))
            } else if let plan {
                Text(verbatim: plan)
            }
            Spacer(minLength: 8)
            Menu {
                Button(L10n.settingsMenuItem) { openSettings() }
                Divider()
                Button(L10n.quitMenuItem) { quit() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.optionsMenu)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// One line above the footer while the panel shows data but the Claude Code status line does
/// not feed it, with the action that fixes it. Secondary text, no alarm colour.
private struct ConnectionNote: View {
    let status: ConnectionStatus
    let error: String?
    let connect: () -> Void
    let repair: () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(L10n.connectionNote(status))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionTitle: String {
        switch status {
        case .needsRepair: L10n.repair
        case .settingsUnreadable: L10n.openSettings
        case .notConnected, .connected: L10n.connect
        }
    }

    private func action() {
        switch status {
        case .needsRepair: repair()
        case .settingsUnreadable: openSettings()
        case .notConnected, .connected: connect()
        }
    }
}

/// A native segmented control across the panel's width (SwiftUI's segmented `Picker` keeps
/// its compact width on macOS).
private struct ProviderPicker: NSViewRepresentable {
    let providers: [Provider]
    @Binding var selection: Provider

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.picker = self
        let labels = providers.map(L10n.providerName)
        if control.segmentCount != labels.count { control.segmentCount = labels.count }
        for (index, label) in labels.enumerated() where control.label(forSegment: index) != label {
            control.setLabel(label, forSegment: index)
        }
        control.selectedSegment = providers.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = control.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: natural.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(picker: self) }

    @MainActor final class Coordinator: NSObject {
        var picker: ProviderPicker

        init(picker: ProviderPicker) { self.picker = picker }

        @objc func changed(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard picker.providers.indices.contains(index) else { return }
            picker.selection = picker.providers[index]
        }
    }
}

/// Formats `TimeDataSource.durationOffset(to: reset)`, which is negative before the reset, as
/// the time left in hours and whole minutes ("1:47", "0:05"), "0:00" once the reset has passed.
/// Being a `DiscreteFormatStyle`, it tells SwiftUI the minute boundaries, so the system redraws
/// the text exactly when it changes.
struct CountdownFormat: DiscreteFormatStyle {
    func format(_ offset: Duration) -> String {
        TimeText.countdown(minutes: Self.minutesLeft(offset))
    }

    /// Next offset with a different text going forward: just past the current minute's end.
    func discreteInput(after offset: Duration) -> Duration? {
        let minutes = Self.minutesLeft(offset)
        return minutes == 0 ? nil : .seconds(-60 * minutes) + .nanoseconds(1)
    }

    /// Next offset with a different text going backward: the start of the previous minute.
    func discreteInput(before offset: Duration) -> Duration? {
        .seconds(-60 * (Self.minutesLeft(offset) + 1))
    }

    /// Whole minutes left, truncated like `TimeText.countdown`.
    private static func minutesLeft(_ offset: Duration) -> Int {
        let left = Duration.zero - offset
        return left > .zero ? Int(left.components.seconds / 60) : 0
    }
}

/// The large used percent of the top block.
private struct BigPercent: View {
    let value: Int

    var body: some View {
        Text(verbatim: "\(value)%")
            .font(.system(size: 30, weight: .semibold))
            .tracking(-0.6)
            .monospacedDigit()
    }
}

/// A 0.5 pt separator inset to the panel's content edges.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1 / displayScale)
            .padding(.horizontal, 14)
    }
}

/// Numbers and verdict lines as the panel shows them.
enum PanelText {
    struct Line {
        let text: String
        let isAccent: Bool
    }

    /// Verdict of the binding window (forecast on): the run-out in the accent, otherwise the
    /// expected reserve at reset in the secondary colour.
    static func topVerdict(_ assessment: Assessment, now: Date) -> Line? {
        line(assessment, now: now) { remainingAtReset in
            L10n.enough(reserve: Int(remainingAtReset.rounded()))
        }
    }

    /// Verdict of a row (forecast on): "enough" in the secondary colour, or the run-out day
    /// and time in the accent.
    static func rowVerdict(_ assessment: Assessment, now: Date) -> Line? {
        line(assessment, now: now) { _ in L10n.enough }
    }

    private static func line(_ assessment: Assessment, now: Date, enough: (Double) -> String) -> Line? {
        let window = assessment.window
        if window.isExpired(at: now) { return nil }
        if window.remainingPercent <= 0 { return Line(text: L10n.limitReached, isAccent: true) }
        switch assessment.verdict {
        case .insufficientData:
            return nil
        case .enough(let remainingAtReset):
            return Line(text: enough(remainingAtReset), isAccent: false)
        case .runsOut(let at):
            return at > now
                ? Line(text: L10n.runsOut(at: at, now: now), isAccent: true)
                : Line(text: L10n.limitReached, isAccent: true)
        }
    }
}
