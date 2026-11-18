import SpoolCore
import SwiftUI

/// One non-binding window under the panel's top block.
///
/// Forecast on: name and used percent, then the reset and the verdict, with the run-out in
/// the accent. Forecast off: name, used percent and reset day, then a thin bar that fills
/// with use.
struct WindowRow: View {
    let assessment: Assessment
    let forecastEnabled: Bool
    let now: Date

    var body: some View {
        if forecastEnabled { forecastRow } else { barRow }
    }

    private var window: LimitWindow { assessment.window }
    private var used: Int { window.displayedUsedPercent(at: now) }

    private var forecastRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.windowName(window.kind))
                Spacer(minLength: 8)
                Text(verbatim: "\(used)%")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13))

            HStack(alignment: .firstTextBaseline) {
                if !window.isExpired(at: now) {
                    Text(L10n.resets(at: window.resetsAt, now: now))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let verdict = PanelText.rowVerdict(assessment, now: now) {
                    Text(verdict.text)
                        .foregroundStyle(verdict.isAccent ? AnyShapeStyle(Theme.accentColor) : AnyShapeStyle(.secondary))
                }
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private var barRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L10n.windowName(window.kind))
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text(verbatim: "\(used)%")
                    .font(.system(size: 13, weight: .semibold))
                if !window.isExpired(at: now) {
                    Text(verbatim: "· " + L10n.clock(window.resetsAt, now: now))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            ThinBar(fraction: Double(used) / 100)
                .padding(.top, 7)
                .padding(.bottom, 2)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// A 5 pt track with a solid fill for the used fraction.
struct ThinBar: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .frame(height: 5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: clamped)
            .accessibilityHidden(true)
    }
}
