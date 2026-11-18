import Foundation
import Testing
@testable import SpoolCore

private func window(used: Double = 50, kind: WindowKind = .session, resetsAt: TimeInterval = 1_000_000) -> LimitWindow {
    LimitWindow(provider: .claude, kind: kind, usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: resetsAt),
                length: WindowLength.session,
                observedAt: Date(timeIntervalSince1970: 0), source: .statusline)
}

@Test func remainingPercentClamps() {
    #expect(window(used: 130).remainingPercent == 0)
    #expect(window(used: -5).remainingPercent == 100)
    #expect(window(used: 40).remainingPercent == 60)
}

@Test func displayedUsedPercentRoundsUpAndClamps() {
    let before = Date(timeIntervalSince1970: 999_000)
    #expect(window(used: 62.4).displayedUsedPercent(at: before) == 63)
    #expect(window(used: 34).displayedUsedPercent(at: before) == 34)
    #expect(window(used: 0.2).displayedUsedPercent(at: before) == 1)
    #expect(window(used: 130).displayedUsedPercent(at: before) == 100)
    #expect(window(used: -5).displayedUsedPercent(at: before) == 0)
}

@Test func displayedUsedPercentReadsFullOnlyAtTheLimit() {
    let before = Date(timeIntervalSince1970: 999_000)
    #expect(window(used: 99.5).displayedUsedPercent(at: before) == 99)
    #expect(window(used: 99.99).displayedUsedPercent(at: before) == 99)
    #expect(window(used: 100).displayedUsedPercent(at: before) == 100)
}

@Test func displayedUsedPercentIsZeroAfterReset() {
    #expect(window(used: 95).displayedUsedPercent(at: Date(timeIntervalSince1970: 1_000_000)) == 0)
}

@Test func startsAtIsResetMinusLength() {
    let w = window()
    #expect(w.startsAt == w.resetsAt.addingTimeInterval(-18_000))
}

@Test func isExpiredAtExactlyResetsAt() {
    let w = window()
    #expect(w.isExpired(at: w.resetsAt))
    #expect(!w.isExpired(at: w.resetsAt.addingTimeInterval(-1)))
}

@Test func isSameInstanceTolerance() {
    let a = window(resetsAt: 1_000_000)
    #expect(a.isSameInstance(as: window(resetsAt: 1_000_120)))
    #expect(!a.isSameInstance(as: window(resetsAt: 1_000_121)))
    #expect(!a.isSameInstance(as: window(kind: .weekly, resetsAt: 1_000_000)))
}

@Test func isWeekly() {
    #expect(!WindowKind.session.isWeekly)
    #expect(WindowKind.weekly.isWeekly)
    #expect(WindowKind.weeklyModel("opus").isWeekly)
}
