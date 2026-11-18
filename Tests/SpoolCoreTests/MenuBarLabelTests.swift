import Foundation
import Testing
@testable import SpoolCore

private let now = Date(timeIntervalSince1970: 1_794_300_000 + 3 * 3600)
private let runOut = now.addingTimeInterval(5_000)

private func assessment(_ verdict: Verdict, kind: WindowKind = .session, used: Double = 62,
                        expired: Bool = false) -> Assessment {
    Assessment(window: LimitWindow(provider: .claude, kind: kind, usedPercent: used,
                                   resetsAt: now.addingTimeInterval(expired ? 0 : 7_200),
                                   length: kind.isWeekly ? WindowLength.week : WindowLength.session,
                                   observedAt: now, source: .statusline),
               verdict: verdict)
}

@Test func forecastRunsOutShowsUntil() {
    let l = MenuBarLabelBuilder.make(binding: assessment(.runsOut(at: runOut)), forecastEnabled: true, now: now)
    #expect(l.text == .until(runOut))
    #expect(l.isAccent)
    #expect(!l.isWeekly)
    #expect(abs(l.usedFraction - 0.62) < 0.0001)
}

@Test func forecastEnoughShowsUsedPercent() {
    let l = MenuBarLabelBuilder.make(binding: assessment(.enough(remainingAtReset: 5)), forecastEnabled: true, now: now)
    #expect(l.text == .percent(62))
    #expect(abs(l.usedFraction - 0.62) < 0.0001)
    #expect(!l.isAccent)
}

@Test func forecastOffNeverAccents() {
    let l = MenuBarLabelBuilder.make(binding: assessment(.runsOut(at: runOut)), forecastEnabled: false, now: now)
    #expect(l.text == .percent(62))
    #expect(!l.isAccent)
}

@Test func roundsUsedUp() {
    let l = MenuBarLabelBuilder.make(binding: assessment(.enough(remainingAtReset: 5), used: 62.4),
                                     forecastEnabled: true, now: now)
    #expect(l.text == .percent(63))
}

@Test func weeklyBindingMarksWeekly() {
    for kind in [WindowKind.weekly, .weeklyModel("Fable")] {
        let l = MenuBarLabelBuilder.make(binding: assessment(.enough(remainingAtReset: 5), kind: kind),
                                         forecastEnabled: true, now: now)
        #expect(l.isWeekly)
    }
}

@Test func noBindingIsNoData() {
    let l = MenuBarLabelBuilder.make(binding: nil, forecastEnabled: true, now: now)
    #expect(l.text == .noData)
    #expect(l.usedFraction == 0)
    #expect(!l.isAccent)
}

@Test func expiredShowsNothingUsed() {
    let l = MenuBarLabelBuilder.make(binding: assessment(.runsOut(at: now), used: 95, expired: true),
                                     forecastEnabled: true, now: now)
    #expect(l.text == .percent(0))
    #expect(l.usedFraction == 0)
    #expect(!l.isAccent)
}

@Test func almostAtLimitShowsNinetyNineWithoutAccent() {
    let l = MenuBarLabelBuilder.make(binding: assessment(.enough(remainingAtReset: 0.5), used: 99.5),
                                     forecastEnabled: true, now: now)
    #expect(l.text == .percent(99))
    #expect(!l.isAccent)
}

@Test func overLimitShowsFullWithAccent() {
    let on = MenuBarLabelBuilder.make(binding: assessment(.runsOut(at: now), used: 104), forecastEnabled: true, now: now)
    #expect(on.text == .percent(100))
    #expect(on.isAccent)
    #expect(on.usedFraction == 1)
    let off = MenuBarLabelBuilder.make(binding: assessment(.runsOut(at: now), used: 104), forecastEnabled: false, now: now)
    #expect(off.text == .percent(100))
    #expect(!off.isAccent)
}
