import Foundation
import Testing
@testable import SpoolCore

@Test func parsesBothWindows() throws {
    let now = Date(timeIntervalSince1970: 1_794_318_000)
    let w = try StatuslinePayload.windows(from: fixture("statusline"), observedAt: now)
    let session = try #require(w.first { $0.kind == .session })
    #expect(session.provider == .claude && session.source == .statusline)
    #expect(session.usedPercent == 34.0)
    #expect(session.resetsAt == Date(timeIntervalSince1970: 1_794_335_400))
    #expect(session.length == WindowLength.session)
    #expect(session.observedAt == now)
    let weekly = try #require(w.first { $0.kind == .weekly })
    #expect(weekly.usedPercent == 58.0)
    #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_794_524_400))
    #expect(weekly.length == WindowLength.week)
}

@Test func nullRateLimitsGivesNoWindows() throws {
    #expect(try StatuslinePayload.windows(from: fixture("statusline-no-limits"), observedAt: .now).isEmpty)
}

@Test func missingWeeklyGivesSessionOnly() throws {
    let json = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1794327000}}}"#
    #expect(try StatuslinePayload.windows(from: Data(json.utf8), observedAt: .now).map(\.kind) == [.session])
}

@Test func acceptsDoubleValues() throws {
    let json = #"{"rate_limits":{"seven_day":{"used_percentage":12.5,"resets_at":1794327000.0}}}"#
    let w = try StatuslinePayload.windows(from: Data(json.utf8), observedAt: .now)
    #expect(w.first?.usedPercent == 12.5)
}

@Test func garbageThrows() {
    #expect(throws: SpoolError.malformedJSON) { try StatuslinePayload.windows(from: Data("nope".utf8), observedAt: .now) }
}

@Test func nonObjectThrows() {
    #expect(throws: SpoolError.notAnObject) { try StatuslinePayload.windows(from: Data("[1]".utf8), observedAt: .now) }
}
