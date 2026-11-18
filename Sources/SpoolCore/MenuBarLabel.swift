import Foundation

public enum LabelText: Equatable, Sendable {
    case noData, percent(Int), until(Date)
}

public struct MenuBarLabel: Equatable, Sendable {
    /// Used share of the window, 0...1; the ring fills with it.
    public var usedFraction: Double
    public var text: LabelText
    public var isAccent: Bool
    public var isWeekly: Bool

    public init(usedFraction: Double, text: LabelText, isAccent: Bool, isWeekly: Bool) {
        self.usedFraction = usedFraction
        self.text = text
        self.isAccent = isAccent
        self.isWeekly = isWeekly
    }
}

public enum MenuBarLabelBuilder {
    public static func make(binding: Assessment?, forecastEnabled: Bool, now: Date) -> MenuBarLabel {
        guard let binding else {
            return MenuBarLabel(usedFraction: 0, text: .noData, isAccent: false, isWeekly: false)
        }
        let w = binding.window
        let isWeekly = w.kind.isWeekly
        if w.isExpired(at: now) {
            return MenuBarLabel(usedFraction: 0, text: .percent(0), isAccent: false, isWeekly: isWeekly)
        }
        let fraction = min(1, max(0, w.usedPercent / 100))
        if w.remainingPercent <= 0 {
            return MenuBarLabel(usedFraction: 1, text: .percent(100), isAccent: forecastEnabled, isWeekly: isWeekly)
        }
        if forecastEnabled, case .runsOut(let at) = binding.verdict, at > now {
            return MenuBarLabel(usedFraction: fraction, text: .until(at), isAccent: true, isWeekly: isWeekly)
        }
        return MenuBarLabel(usedFraction: fraction, text: .percent(w.displayedUsedPercent(at: now)),
                            isAccent: false, isWeekly: isWeekly)
    }
}
