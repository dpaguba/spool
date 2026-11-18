import Foundation
import Testing
@testable import SpoolCore

@Suite struct ThresholdTrackerTests {
    let r = Date(timeIntervalSince1970: 1_800_000_000)
    let th: [Double] = [50, 90]

    func win(_ used: Double, resets: Date? = nil, kind: WindowKind = .session) -> LimitWindow {
        LimitWindow(provider: .claude, kind: kind, usedPercent: used, resetsAt: resets ?? r,
                    length: WindowLength.session, observedAt: r, source: .oauth)
    }

    @Test func belowFirstIsSilent() {
        var t = ThresholdTracker()
        #expect(t.evaluate(win(49), thresholds: th, now: r) == nil)
    }

    @Test func crossingFiresOnce() {
        var t = ThresholdTracker()
        #expect(t.evaluate(win(51), thresholds: th, now: r) == 50)
        #expect(t.evaluate(win(55), thresholds: th, now: r) == nil)
        #expect(t.evaluate(win(91), thresholds: th, now: r) == 90)
        #expect(t.evaluate(win(95), thresholds: th, now: r) == nil)
    }

    @Test func jumpFiresOnlyHighest() {
        var t = ThresholdTracker()
        #expect(t.evaluate(win(95), thresholds: th, now: r) == 90)
        #expect(t.evaluate(win(96), thresholds: th, now: r) == nil)
    }

    @Test func newWindowRearms() {
        var t = ThresholdTracker()
        #expect(t.evaluate(win(95), thresholds: th, now: r) == 90)
        let next = r.addingTimeInterval(5 * 3600)
        #expect(t.evaluate(win(52, resets: next), thresholds: th, now: r) == 50)
    }

    @Test func skewedResetIsSameWindow() {
        var t = ThresholdTracker()
        #expect(t.evaluate(win(51), thresholds: th, now: r) == 50)
        #expect(t.evaluate(win(52, resets: r.addingTimeInterval(30)), thresholds: th, now: r) == nil)
    }

    @Test func weeklyIgnored() {
        var t = ThresholdTracker()
        #expect(t.evaluate(win(95, kind: .weekly), thresholds: th, now: r) == nil)
        #expect(t.entryCount == 0)
    }

    @Test func prunesOldEntries() {
        var t = ThresholdTracker()
        _ = t.evaluate(win(60), thresholds: th, now: r)
        #expect(t.entryCount == 1)
        let later = r.addingTimeInterval(86_400 + 1)
        let fresh = later.addingTimeInterval(3600)
        _ = t.evaluate(win(10, resets: fresh), thresholds: th, now: later)
        #expect(t.entryCount == 1)
    }

    @Test func codableRoundTrip() throws {
        var t = ThresholdTracker()
        _ = t.evaluate(win(95), thresholds: th, now: r)
        let back = try JSONDecoder().decode(ThresholdTracker.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
