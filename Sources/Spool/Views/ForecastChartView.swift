import AppKit
import Charts
import SpoolCore
import SwiftUI

/// Usage of the binding window from its start to now: a step line of the stored samples, a
/// dashed projection along the current pace, a rule at the reset and a hairline at 100%. The
/// projection is drawn in the accent only when the window runs out.
struct ForecastChartView: View {
    let window: LimitWindow
    let samples: [UsageSample]
    let verdict: Verdict
    let now: Date

    @Environment(\.displayScale) private var displayScale
    /// Width of the chart, for deciding whether the "now" label fits between the end labels.
    @State private var width: CGFloat = 272

    var body: some View {
        Chart {
            RuleMark(y: .value(Series.limit, 100))
                .foregroundStyle(Color(nsColor: .separatorColor))
                .lineStyle(StrokeStyle(lineWidth: 1 / displayScale))
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    Text(verbatim: "100%")
                        .font(Font(Self.labelFont))
                        .foregroundStyle(.secondary)
                }

            RuleMark(x: .value(Series.reset, window.resetsAt))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1))

            ForEach(Array(usagePoints.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(Series.time, point.t), y: .value(Series.used, point.usedPercent),
                         series: .value(Series.series, Series.usage))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            if let end = projectionEnd {
                ForEach([UsageSample(t: now, usedPercent: used), end], id: \.t) { point in
                    LineMark(x: .value(Series.time, point.t), y: .value(Series.used, point.usedPercent),
                             series: .value(Series.series, Series.projection))
                        .foregroundStyle(projectionColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
                }
            }

            PointMark(x: .value(Series.time, now), y: .value(Series.used, used))
                .symbolSize(30)
                .foregroundStyle(Color.primary)
        }
        .chartXScale(domain: window.startsAt...window.resetsAt)
        .chartYScale(domain: 0...100)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: anchor(for: date), collisionResolution: .disabled,
                                   horizontalSpacing: 0) {
                        Text(axisText(for: date))
                            .font(Font(Self.labelFont))
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
        }
        .frame(height: 74)
        // Room above the 100% hairline for its label, which draws outside the chart's frame.
        .padding(.top, 13)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityHidden(true)
    }

    // MARK: - Data

    private enum Series {
        static let limit = "limit"
        static let reset = "reset"
        static let time = "time"
        static let used = "used"
        static let series = "series"
        static let usage = "usage"
        static let projection = "projection"
    }

    /// Current used percent at `now`, clamped to the chart.
    private var used: Double { min(100, max(0, window.usedPercent)) }

    /// Samples inside the window up to now, starting from zero at the window start (fixed
    /// windows reset to zero) and ending at the current value at now.
    private var usagePoints: [UsageSample] {
        let start = window.startsAt
        var points = samples
            .filter { $0.t > start && $0.t < now }
            .map { UsageSample(t: $0.t, usedPercent: min(100, max(0, $0.usedPercent))) }
        points.insert(UsageSample(t: start, usedPercent: 0), at: 0)
        points.append(UsageSample(t: now, usedPercent: used))
        return points
    }

    /// Where the current pace leads: the 100% point for a run-out, the projected use at reset
    /// for enough, nothing without a forecast or once the limit is used up.
    private var projectionEnd: UsageSample? {
        switch verdict {
        case .runsOut(let at) where at > now:
            UsageSample(t: min(at, window.resetsAt), usedPercent: 100)
        case .enough(let remainingAtReset) where window.resetsAt > now:
            UsageSample(t: window.resetsAt, usedPercent: min(100, max(used, 100 - remainingAtReset)))
        default:
            nil
        }
    }

    private var projectionColor: Color {
        if case .runsOut = verdict { return Theme.accentColor }
        return .secondary
    }

    // MARK: - Axis

    /// Axis labels: 9.5 pt with monospaced digits, so times keep their width as they change.
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)

    /// Window start, reset, and now when its centred label clears both end labels.
    private var axisDates: [Date] {
        let span = window.resetsAt.timeIntervalSince(window.startsAt)
        guard span > 0, now > window.startsAt, now < window.resetsAt else {
            return [window.startsAt, window.resetsAt]
        }
        let x = width * now.timeIntervalSince(window.startsAt) / span
        let half = textWidth(L10n.chartNow) / 2
        let gap: CGFloat = 6
        let clearsStart = x - half >= textWidth(axisText(for: window.startsAt)) + gap
        let clearsReset = x + half <= width - textWidth(axisText(for: window.resetsAt)) - gap
        return clearsStart && clearsReset ? [window.startsAt, now, window.resetsAt] : [window.startsAt, window.resetsAt]
    }

    private func textWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: Self.labelFont]).size().width)
    }

    private func anchor(for date: Date) -> UnitPoint {
        if date == window.startsAt { return .topLeading }
        if date == window.resetsAt { return .topTrailing }
        return .top
    }

    /// "now" at now; at the ends, the time (with a weekday when not today), or for a window
    /// longer than a day the date and time, so a week's start and reset do not read the same.
    private func axisText(for date: Date) -> String {
        if date == now && date != window.startsAt && date != window.resetsAt { return L10n.chartNow }
        return window.length > 86_400
            ? TimeText.dateAndTime(date, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
            : L10n.clock(date, now: now)
    }
}
