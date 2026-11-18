import Foundation
import Testing
@testable import SpoolCore

struct FetchGateTests {
    let t = Date(timeIntervalSince1970: 1_794_320_000)

    @Test func freshGateAllows() {
        #expect(FetchGate().allows(now: t))
    }

    @Test func successWaitsFifteenMinutes() {
        var g = FetchGate()
        g.recordSuccess(now: t)
        #expect(!g.allows(now: t.addingTimeInterval(899)))
        #expect(g.allows(now: t.addingTimeInterval(900)))
    }

    @Test func rateLimitedHonoursRetryAfter() {
        var g = FetchGate()
        g.recordRateLimited(retryAfter: 3600, now: t)
        #expect(!g.allows(now: t.addingTimeInterval(3599)))
        #expect(g.allows(now: t.addingTimeInterval(3600)))
        g.recordRateLimited(retryAfter: nil, now: t)
        #expect(!g.allows(now: t.addingTimeInterval(899)))
        #expect(g.allows(now: t.addingTimeInterval(900)))
        g.recordRateLimited(retryAfter: 10, now: t)
        #expect(!g.allows(now: t.addingTimeInterval(899)))
    }

    @Test func failuresBackOffAndSuccessResets() {
        var g = FetchGate()
        for delay in [900.0, 1800, 3600, 7200, 14_400, 14_400] {
            g.recordFailure(now: t)
            #expect(!g.allows(now: t.addingTimeInterval(delay - 1)))
            #expect(g.allows(now: t.addingTimeInterval(delay)))
        }
        g.recordSuccess(now: t)
        g.recordFailure(now: t)
        #expect(!g.allows(now: t.addingTimeInterval(899)))
        #expect(g.allows(now: t.addingTimeInterval(900)))
    }

    @Test func nextAttemptFollowsTheGate() {
        var g = FetchGate()
        #expect(g.nextAttempt == nil)
        g.recordRateLimited(retryAfter: 3600, now: t)
        #expect(g.nextAttempt == t.addingTimeInterval(3600))
        g.recordFailure(now: t)
        #expect(g.nextAttempt == t.addingTimeInterval(900))
    }

    @Test func retryAfterSeconds() {
        #expect(RetryAfter.interval("120", now: t) == 120)
        #expect(RetryAfter.interval(" 0 ", now: t) == 0)
    }

    @Test func retryAfterHTTPDate() {
        // t is Tue, 10 Nov 2026 14:13:20 GMT.
        #expect(RetryAfter.interval("Tue, 10 Nov 2026 15:13:20 GMT", now: t) == 3600)
        #expect(RetryAfter.interval("Tue, 10 Nov 2026 14:12:20 GMT", now: t) == 0)
    }

    @Test func retryAfterIgnoresAnythingElse() {
        for value in [nil, "", "soon", "-5", "1.5", "2026-11-10T15:13:20Z", "Tue, 10 Nov 2026 15:13:20 PST"] {
            #expect(RetryAfter.interval(value, now: t) == nil)
        }
    }

    @Test func retryAfterIsCappedAtTheMaximumBackoff() {
        var g = FetchGate()
        g.recordRateLimited(retryAfter: 1_794_320_000, now: t)
        #expect(g.nextAttempt == t.addingTimeInterval(14_400))
        g.recordRateLimited(retryAfter: 1_200, now: t)
        #expect(g.nextAttempt == t.addingTimeInterval(1_200))
    }

    @Test func clampPullsAFarFutureSavedGateBack() throws {
        // As saved by a build without the cap: a Retry-After that pointed to 2040.
        let far = Date(timeIntervalSince1970: 2_208_988_800)
        let json = #"{"nextAllowed": \#(far.timeIntervalSinceReferenceDate), "failures": 0}"#
        var g = try JSONDecoder().decode(FetchGate.self, from: Data(json.utf8))
        #expect(g.nextAttempt == far)
        g.clamp(now: t)
        #expect(g.nextAttempt == t.addingTimeInterval(14_400))
        #expect(g.allows(now: t.addingTimeInterval(14_400)))
    }

    @Test func clampLeavesAGateWithinTheCapAlone() {
        var fresh = FetchGate()
        fresh.clamp(now: t)
        #expect(fresh == FetchGate())
        var g = FetchGate()
        g.recordRateLimited(retryAfter: 3_600, now: t)
        let before = g
        g.clamp(now: t)
        #expect(g == before)
        g.recordFailure(now: t)
        g.recordFailure(now: t)
        let backedOff = g
        g.clamp(now: t)
        #expect(g == backedOff)
    }

    @Test func codableRoundTrip() throws {
        var g = FetchGate()
        g.recordFailure(now: t)
        let back = try JSONDecoder().decode(FetchGate.self, from: JSONEncoder().encode(g))
        #expect(back == g)
    }
}
