import Foundation
import Testing
@testable import SpoolCore

private let start = Date(timeIntervalSince1970: 1_794_300_000)

private func session(used: Double) -> LimitWindow {
    LimitWindow(provider: .claude, kind: .session, usedPercent: used,
                resetsAt: start.addingTimeInterval(18_000), length: WindowLength.session,
                observedAt: start, source: .statusline)
}

private func close(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) <= 1 }

private func expectRunsOut(_ v: Verdict, _ expected: Date) {
    guard case .runsOut(let at) = v else { Issue.record("expected runsOut, got \(v)"); return }
    #expect(close(at, expected))
}

private func expectEnough(_ v: Verdict, _ expected: Double) {
    guard case .enough(let r) = v else { Issue.record("expected enough, got \(v)"); return }
    #expect(abs(r - expected) <= 0.01)
}

@Test func fastPaceRunsOutBeforeReset() {
    let now = start.addingTimeInterval(3 * 3600)
    let v = PaceForecaster.verdict(for: session(used: 60),
                                   samples: [UsageSample(t: now.addingTimeInterval(-1800), usedPercent: 45)], now: now)
    expectRunsOut(v, start.addingTimeInterval(4 * 3600 + 20 * 60))
}

@Test func idleMeansEnough() {
    let now = start.addingTimeInterval(3 * 3600)
    let v = PaceForecaster.verdict(for: session(used: 60),
                                   samples: [UsageSample(t: now.addingTimeInterval(-1800), usedPercent: 60)], now: now)
    expectEnough(v, 40)
}

@Test func slowPaceProjectsLeftover() {
    let now = start.addingTimeInterval(3 * 3600)
    let v = PaceForecaster.verdict(for: session(used: 60),
                                   samples: [UsageSample(t: now.addingTimeInterval(-1800), usedPercent: 55)], now: now)
    expectEnough(v, 20)
}

@Test func tooEarlyIsInsufficient() {
    let now = start.addingTimeInterval(240)
    #expect(PaceForecaster.verdict(for: session(used: 5), samples: [], now: now) == .insufficientData)
}

@Test func noOldSampleFallsBackToWindowAverage() {
    let now = start.addingTimeInterval(3 * 3600)
    let v = PaceForecaster.verdict(for: session(used: 60),
                                   samples: [UsageSample(t: start.addingTimeInterval(2 * 3600 + 50 * 60), usedPercent: 58)],
                                   now: now)
    expectEnough(v, 0)
}

@Test func overLimitRunsOutNow() {
    let now = start.addingTimeInterval(3 * 3600)
    for used in [100.0, 130.0] {
        expectRunsOut(PaceForecaster.verdict(for: session(used: used), samples: [], now: now), now)
    }
}

@Test func expiredIsFull() {
    let w = session(used: 80)
    let v = PaceForecaster.verdict(for: w, samples: [], now: w.resetsAt.addingTimeInterval(1))
    expectEnough(v, 100)
}

@Test func weeklyUsesAverageSinceWeekStart() {
    let w0 = start
    let w = LimitWindow(provider: .claude, kind: .weekly, usedPercent: 40,
                        resetsAt: w0.addingTimeInterval(WindowLength.week), length: WindowLength.week,
                        observedAt: w0, source: .statusline)
    let now = w0.addingTimeInterval(2 * 86_400)
    let v = PaceForecaster.verdict(for: w,
                                   samples: [UsageSample(t: now.addingTimeInterval(-1800), usedPercent: 39.9)], now: now)
    expectRunsOut(v, w0.addingTimeInterval(5 * 86_400))
}

@Test func oldGrowthIsNotChargedToTheLastHalfHour() {
    // The newest sample at or before 30 minutes ago is from 11:00, hours older: the 48% since
    // then spread over 3 h 25 min, not over the last 30 minutes.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hour, minute: minute))!
    }
    let window = LimitWindow(provider: .claude, kind: .session, usedPercent: 50, resetsAt: at(16, 10),
                             length: WindowLength.session, observedAt: at(14, 20), source: .statusline)
    let samples = [UsageSample(t: at(11, 0), usedPercent: 2), UsageSample(t: at(14, 20), usedPercent: 50)]
    let rate = 48.0 / (3 * 3600 + 25 * 60)
    expectEnough(PaceForecaster.verdict(for: window, samples: samples, now: at(14, 25)),
                 50 - rate * (60 * 105))
}

private func nov17(_ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hour, minute: minute))!
}

/// The 5-hour window that resets at 16:10, with `used` percent used.
private func resetsAt1610(used: Double) -> LimitWindow {
    LimitWindow(provider: .claude, kind: .session, usedPercent: used, resetsAt: nov17(16, 10),
                length: WindowLength.session, observedAt: nov17(14, 25), source: .statusline)
}

@Test func burstAfterAnIdleGapStillRunsOut() {
    // Idle over lunch (no lines while nothing changes), then 29% in 24 minutes.
    let samples = [(11, 30, 20.0), (14, 1, 21.0), (14, 10, 30.0), (14, 18, 40.0), (14, 25, 50.0)]
        .map { UsageSample(t: nov17($0.0, $0.1), usedPercent: $0.2) }
    let now = nov17(14, 25)
    let rate = 29.0 / (24 * 60)
    let v = PaceForecaster.verdict(for: resetsAt1610(used: 50), samples: samples, now: now)
    guard case .runsOut(let at) = v else { Issue.record("expected runsOut, got \(v)"); return }
    #expect(abs(at.timeIntervalSince(now.addingTimeInterval(50 / rate))) <= 60)
    #expect(abs(at.timeIntervalSince(nov17(15, 6))) <= 60)
}

@Test func unseenJumpThenSteadyWorkUsesTheInsideSlope() {
    // The jump to 40% happened outside Claude Code and lands on the first sample inside the
    // last 30 minutes; the work since is 10% in 24 minutes.
    let samples = [(11, 0, 2.0), (14, 1, 40.0), (14, 13, 45.0), (14, 25, 50.0)]
        .map { UsageSample(t: nov17($0.0, $0.1), usedPercent: $0.2) }
    let rate = 10.0 / (24 * 60)
    expectEnough(PaceForecaster.verdict(for: resetsAt1610(used: 50), samples: samples, now: nov17(14, 25)),
                 50 - rate * (105 * 60))
}

@Test func insideSpanBelowTheMinimumFallsBackToTheSpreadRate() {
    // Only four minutes inside the lookback: too short for a slope of its own.
    let samples = [UsageSample(t: nov17(11, 0), usedPercent: 2), UsageSample(t: nov17(14, 21), usedPercent: 40)]
    let rate = 48.0 / (3 * 3600 + 25 * 60)
    expectEnough(PaceForecaster.verdict(for: resetsAt1610(used: 50), samples: samples, now: nov17(14, 25)),
                 50 - rate * (105 * 60))
}
