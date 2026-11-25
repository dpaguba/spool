import Foundation
import Testing
@testable import SpoolCore

private let r = Date(timeIntervalSince1970: 1_800_000_000)

private func obs(_ offset: TimeInterval, used: Double, resetsAt: Date,
                 source: DataSource = .statusline) -> UsageObservation {
    let t = r.addingTimeInterval(offset)
    return UsageObservation(t: t, windows: [
        LimitWindow(provider: .claude, kind: .session, usedPercent: used, resetsAt: resetsAt,
                    length: WindowLength.session, observedAt: t, source: source),
    ])
}

@Test func mergeKeepsHighestWithinInstance() {
    let o = [obs(-300, used: 60, resetsAt: r), obs(-200, used: 64, resetsAt: r), obs(-100, used: 58, resetsAt: r)]
    let cur = WindowMerge.current(from: o)
    #expect(cur.count == 1)
    #expect(cur[0].usedPercent == 64)
}

@Test func mergeLaterResetStartsNewWindow() {
    let next = r.addingTimeInterval(WindowLength.session)
    let cur = WindowMerge.current(from: [obs(-100, used: 95, resetsAt: r), obs(10, used: 3, resetsAt: next)])
    #expect(cur.count == 1)
    #expect(cur[0].usedPercent == 3)
    #expect(cur[0].resetsAt == next)
}

@Test func mergeToleratesSourceSkew() {
    let o = [obs(-200, used: 50, resetsAt: r), obs(-100, used: 52, resetsAt: r.addingTimeInterval(40), source: .oauth)]
    let cur = WindowMerge.current(from: o)
    #expect(cur.count == 1)
    #expect(cur[0].usedPercent == 52)
}

@Test func samplesAreSortedAndMonotonic() {
    let o = [obs(-100, used: 58, resetsAt: r), obs(-300, used: 60, resetsAt: r), obs(-200, used: 64, resetsAt: r),
             obs(-50, used: 5, resetsAt: r.addingTimeInterval(WindowLength.session))]
    let target = o[0].windows[0]
    let s = WindowMerge.samples(for: target, in: o)
    #expect(s.map(\.t) == [-300, -200, -100].map { r.addingTimeInterval($0) })
    #expect(s.map(\.usedPercent) == [60, 64, 64])
}

// MARK: - Weekly usage that drops within one window (a limit reset by Anthropic)

private let week = r.addingTimeInterval(2 * 86_400)
private let fiveHours = r.addingTimeInterval(5_000)
/// The 5-hour window that starts with the first request after the reset.
private let fiveHoursAfterReset = r.addingTimeInterval(17_000)

private func payload(_ offset: TimeInterval, weekly: Double, session: (Double, Date)? = nil,
                     source: DataSource = .statusline) -> UsageObservation {
    let t = r.addingTimeInterval(offset)
    var windows: [LimitWindow] = []
    if let (used, resetsAt) = session {
        windows.append(LimitWindow(provider: .claude, kind: .session, usedPercent: used, resetsAt: resetsAt,
                                   length: WindowLength.session, observedAt: t, source: source))
    }
    windows.append(LimitWindow(provider: .claude, kind: .weekly, usedPercent: weekly, resetsAt: week,
                               length: WindowLength.week, observedAt: t, source: source))
    return UsageObservation(t: t, windows: windows)
}

private func weekly(_ windows: [LimitWindow]) -> LimitWindow? {
    windows.first { $0.kind == .weekly }
}

/// Claude Code's own record of the reset: the 5-hour window starts over and the weekly use drops
/// to 0, while the weekly reset time stays the same.
private let resetHistory = [
    payload(-600, weekly: 99, session: (91, fiveHours)),
    payload(-300, weekly: 100, session: (95, fiveHours)),
    payload(0, weekly: 0, session: (0, fiveHoursAfterReset)),
]

@Test func weeklyFollowsAResetThatKeepsTheResetTime() {
    #expect(weekly(WindowMerge.current(from: resetHistory))?.usedPercent == 0)
}

@Test func idleSessionsDoNotBringBackTheWeeklyUseFromBeforeAReset() {
    // An idle Claude Code session redraws its status line with the numbers it last received:
    // with its 5-hour window from before the reset, or without one once that window has ended.
    let o = resetHistory + [
        payload(60, weekly: 99, session: (91, fiveHours)),
        payload(120, weekly: 78),
        payload(180, weekly: 3, session: (4, fiveHoursAfterReset)),
        payload(240, weekly: 65),
        payload(250, weekly: 2, session: (3, fiveHoursAfterReset)),
    ]
    #expect(weekly(WindowMerge.current(from: o))?.usedPercent == 3)
    let target = resetHistory[0].windows[1]
    #expect(WindowMerge.samples(for: target, in: o).map(\.usedPercent) == [99, 100, 0, 0, 0, 3, 3, 3])
}

@Test func weeklyWithoutA5HourWindowKeepsTheHighest() {
    let o = [payload(-300, weekly: 34), payload(-200, weekly: 40), payload(-100, weekly: 38)]
    #expect(weekly(WindowMerge.current(from: o))?.usedPercent == 40)
}

@Test func weeklyFromAFetchedSourceIsTakenAsItIs() {
    // A fetched source (the usage API, Codex) answers for the moment it was asked, so a later
    // answer replaces an earlier one, also downwards.
    let o = [
        payload(-300, weekly: 100, session: (95, fiveHours)),
        payload(0, weekly: 12, source: .oauth),
        payload(60, weekly: 78),
    ]
    #expect(weekly(WindowMerge.current(from: o))?.usedPercent == 12)
}
