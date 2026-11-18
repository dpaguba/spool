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
