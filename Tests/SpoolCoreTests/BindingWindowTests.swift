import Foundation
import Testing
@testable import SpoolCore

private let now = Date(timeIntervalSince1970: 1_794_300_000 + 3 * 3600)

private func item(_ kind: WindowKind, used: Double, _ verdict: Verdict, expired: Bool = false) -> Assessment {
    let length = kind.isWeekly ? WindowLength.week : WindowLength.session
    let resetsAt = expired ? now.addingTimeInterval(-60) : now.addingTimeInterval(7_200)
    return Assessment(window: LimitWindow(provider: .claude, kind: kind, usedPercent: used, resetsAt: resetsAt,
                                          length: length, observedAt: now, source: .statusline),
                      verdict: verdict)
}

private let enough = Verdict.enough(remainingAtReset: 10)

// The 5-hour window is shown whenever it has data.

@Test func sessionWinsOverWeeklyThatRunsOut() {
    let s = item(.session, used: 40, enough)
    let w = item(.weekly, used: 97, .runsOut(at: now.addingTimeInterval(3_600)))
    #expect(BindingWindow.pick([w, s], forecastEnabled: true, now: now) == s)
    #expect(BindingWindow.pick([w, s], forecastEnabled: false, now: now) == s)
}

@Test func sessionWinsOverLowerWeekly() {
    let s = item(.session, used: 40, enough)
    let w = item(.weekly, used: 97, enough)
    #expect(BindingWindow.pick([w, s], forecastEnabled: true, now: now) == s)
    #expect(BindingWindow.pick([w, s], forecastEnabled: false, now: now) == s)
}

@Test func expiredSessionStillWins() {
    let s = item(.session, used: 95, .runsOut(at: now), expired: true)
    let w = item(.weekly, used: 30, enough)
    let m = item(.weeklyModel("Fable"), used: 99, .runsOut(at: now.addingTimeInterval(600)))
    #expect(BindingWindow.pick([m, w, s], forecastEnabled: true, now: now) == s)
}

// Without a 5-hour window the limit that stops the user first wins.

@Test func withoutSessionEarliestRunOutWins() {
    let w = item(.weekly, used: 60, .runsOut(at: now.addingTimeInterval(86_400 * 2)))
    let m = item(.weeklyModel("Fable"), used: 60, .runsOut(at: now.addingTimeInterval(3_600)))
    #expect(BindingWindow.pick([w, m], forecastEnabled: true, now: now) == m)
}

@Test func withoutSessionRunOutBeatsLowerRemaining() {
    let w = item(.weekly, used: 40, .runsOut(at: now.addingTimeInterval(3_600)))
    let m = item(.weeklyModel("Fable"), used: 97, enough)
    #expect(BindingWindow.pick([m, w], forecastEnabled: true, now: now) == w)
}

@Test func withoutSessionLowestRemainingWhenNoneRunsOut() {
    let w = item(.weekly, used: 14, enough)
    let m = item(.weeklyModel("Fable"), used: 62, enough)
    #expect(BindingWindow.pick([w, m], forecastEnabled: true, now: now) == m)
}

@Test func withoutSessionForecastOffUsesLowestRemaining() {
    let w = item(.weekly, used: 40, .runsOut(at: now.addingTimeInterval(3_600)))
    let m = item(.weeklyModel("Fable"), used: 97, enough)
    #expect(BindingWindow.pick([w, m], forecastEnabled: false, now: now) == m)
}

@Test func tiePrefersWeeklyOverModel() {
    let m = item(.weeklyModel("Fable"), used: 50, enough)
    let w = item(.weekly, used: 50, enough)
    #expect(BindingWindow.pick([m, w], forecastEnabled: true, now: now) == w)
    #expect(BindingWindow.pick([m, w], forecastEnabled: false, now: now) == w)
}

@Test func withoutSessionExpiredCountsAsFull() {
    let w = item(.weekly, used: 95, .runsOut(at: now), expired: true)
    let m = item(.weeklyModel("Fable"), used: 30, enough)
    #expect(BindingWindow.pick([w, m], forecastEnabled: true, now: now) == m)
    #expect(BindingWindow.pick([w, m], forecastEnabled: false, now: now) == m)
}

@Test func emptyGivesNil() {
    #expect(BindingWindow.pick([], forecastEnabled: true, now: now) == nil)
}
