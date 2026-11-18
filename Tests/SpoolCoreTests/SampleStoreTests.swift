import Foundation
import Testing
@testable import SpoolCore

private func tempPaths() -> SpoolPaths {
    SpoolPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func window(_ used: Double, resetsAt: Date = base.addingTimeInterval(3600),
                    kind: WindowKind = .session, observedAt: Date = base) -> LimitWindow {
    LimitWindow(provider: .claude, kind: kind, usedPercent: used, resetsAt: resetsAt,
                length: kind.isWeekly ? WindowLength.week : WindowLength.session,
                observedAt: observedAt, source: .statusline)
}

@Test func appendCreatesDirectoryAndOneLine() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let w = [window(60)]
    #expect(try store.append(w, at: base) == true)
    #expect(try store.load() == [UsageObservation(t: base, windows: w)])
}

@Test func appendSkipsIdenticalObservation() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    #expect(try store.append([window(60, observedAt: base)], at: base) == true)
    let later = base.addingTimeInterval(60)
    #expect(try store.append([window(60, observedAt: later)], at: later) == false)
    #expect(try store.load().count == 1)
}

@Test func appendKeepsChangedObservation() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    #expect(try store.append([window(60)], at: base) == true)
    #expect(try store.append([window(61)], at: base.addingTimeInterval(60)) == true)
    #expect(try store.load().count == 2)
}

@Test func dedupeIgnoresSubSecondNoiseInTheResetTime() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let reset = base.addingTimeInterval(3_600)
    #expect(try store.append([window(60, resetsAt: reset)], at: base) == true)
    // The same reset time one ulp apart, as a stored date with fractional seconds comes back
    // through `secondsSince1970`.
    let later = base.addingTimeInterval(60)
    #expect(try store.append([window(60, resetsAt: reset.addingTimeInterval(1e-7), observedAt: later)], at: later) == false)
    #expect(try store.load().count == 1)
}

@Test func dedupeTellsSourcesApart() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    #expect(try store.append([window(60)], at: base) == true)
    var oauth = window(60)
    oauth.source = .oauth
    #expect(try store.append([oauth], at: base.addingTimeInterval(60)) == true)
    #expect(try store.load().map { $0.windows[0].source } == [.statusline, .oauth])
}

@Test func loadSkipsCorruptLines() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    _ = try store.append([window(10)], at: base)
    let handle = try FileHandle(forWritingTo: paths.observations)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"broken\n".utf8))
    try handle.close()
    _ = try store.append([window(20)], at: base.addingTimeInterval(60))
    #expect(try store.load().count == 2)
}

@Test func compactDropsFullyExpiredObservations() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let now = base.addingTimeInterval(10_000)
    let expired = window(50, resetsAt: base.addingTimeInterval(3600))
    let weekly = window(30, resetsAt: base.addingTimeInterval(500_000), kind: .weekly)
    _ = try store.append([expired], at: base)
    _ = try store.append([expired, weekly], at: base.addingTimeInterval(10))
    _ = try store.append([window(51, resetsAt: base.addingTimeInterval(3601))], at: base.addingTimeInterval(20))
    try store.compact(now: now)
    let loaded = try store.load()
    // The running week, and the newest 5-hour observation, kept although it has reset.
    #expect(loaded.count == 2)
    #expect(loaded.first?.windows.contains(weekly) == true)
    #expect(loaded.last?.t == base.addingTimeInterval(20))
}

private func lines(_ paths: SpoolPaths) throws -> [String] {
    try String(contentsOf: paths.observations, encoding: .utf8).components(separatedBy: "\n")
}

private func inode(_ paths: SpoolPaths) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: paths.observations.path)[.systemFileNumber] as? Int
}

private func modified(_ paths: SpoolPaths) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: paths.observations.path)[.modificationDate] as? Date
}

/// `count` observations of a slowly growing 5-hour window, written in one go.
private func writeObservations(_ count: Int, to paths: SpoolPaths) throws -> UsageObservation {
    try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    var last: UsageObservation?
    for i in 0..<count {
        let t = base.addingTimeInterval(Double(i))
        let obs = UsageObservation(t: t, windows: [
            window(Double(i % 100), resetsAt: base.addingTimeInterval(Double(i / 100) * 18_000 + 18_000), observedAt: t),
            window(Double(i % 100) / 4, resetsAt: base.addingTimeInterval(500_000), kind: .weekly, observedAt: t),
        ])
        data.append(try encoder.encode(obs))
        data.append(0x0A)
        last = obs
    }
    try data.write(to: paths.observations)
    return try #require(last)
}

@Test func lastObservationMatchesLoadOnALargeFile() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let last = try writeObservations(6_000, to: paths)
    #expect(try store.lastObservation() == last)
    #expect(try store.load().last == last)
    let size = try Data(contentsOf: paths.observations).count
    #expect(try store.append(last.windows, at: base.addingTimeInterval(7_000)) == false)
    #expect(try Data(contentsOf: paths.observations).count == size)
    var changed = last.windows
    changed[0].usedPercent += 1
    #expect(try store.append(changed, at: base.addingTimeInterval(7_001)) == true)
    #expect(try store.load().count == 6_001)
    #expect(try store.lastObservation()?.windows == changed)
}

@Test func lastObservationLooksBehindCorruptLinesAcrossChunks() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let last = try writeObservations(3, to: paths)
    // More corrupt bytes after the last valid line than one tail chunk holds.
    let junk = String(repeating: "{\"broken\": \"" + String(repeating: "x", count: 200) + "\n",
                      count: SampleStore.tailChunk / 100)
    let handle = try FileHandle(forWritingTo: paths.observations)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(junk.utf8))
    try handle.close()
    #expect(try store.lastObservation() == last)
    #expect(try store.lastObservation() == store.load().last)
    #expect(try store.append(last.windows, at: base.addingTimeInterval(10)) == false)
}

@Test func tornLastLineDedupesAndIsClosedBeforeTheNextLine() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    _ = try store.append([window(10)], at: base)
    let handle = try FileHandle(forWritingTo: paths.observations)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"t\":18000".utf8))
    try handle.close()
    // The torn line is not an observation, so the repeat of the last valid one is a repeat.
    #expect(try store.append([window(10)], at: base.addingTimeInterval(30)) == false)
    #expect(try store.append([window(20)], at: base.addingTimeInterval(60)) == true)
    #expect(try store.load().map { $0.windows[0].usedPercent } == [10, 20])
    let text = try lines(paths)
    #expect(text.count == 4)
    #expect(text[1] == "{\"t\":18000")
    #expect(text[2].contains("\"usedPercent\":20"))
    #expect(text[3].isEmpty)
}

@Test func repeatMovesModificationTimeOnly() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    #expect(try store.append([window(60)], at: base) == true)
    let bytes = try Data(contentsOf: paths.observations)
    let node = try inode(paths)
    let later = base.addingTimeInterval(600)
    #expect(try store.append([window(60, observedAt: later)], at: later) == false)
    #expect(try Data(contentsOf: paths.observations) == bytes)
    #expect(try inode(paths) == node)
    #expect(try modified(paths) == later)
    #expect(store.lastModified() == later)
    // Never moved back by a repeat stamped earlier.
    #expect(try store.append([window(60)], at: base.addingTimeInterval(300)) == false)
    #expect(try modified(paths) == later)
}

@Test func compactWithNothingToDropLeavesTheFileAlone() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    _ = try store.append([window(10)], at: base)
    _ = try store.append([window(20)], at: base.addingTimeInterval(60))
    let stamp = base.addingTimeInterval(120)
    _ = try store.append([window(20)], at: stamp)
    let bytes = try Data(contentsOf: paths.observations)
    let node = try inode(paths)
    try store.compact(now: base.addingTimeInterval(1_000))
    #expect(try Data(contentsOf: paths.observations) == bytes)
    #expect(try inode(paths) == node)
    #expect(try modified(paths) == stamp)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.directory.path).filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
}

@Test func compactKeepsTheNewestObservationOfEachWindowAfterItsReset() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let sessionReset = base.addingTimeInterval(3_600)
    let weekReset = base.addingTimeInterval(7_200)
    _ = try store.append([window(30, resetsAt: sessionReset), window(40, resetsAt: weekReset, kind: .weekly)], at: base)
    _ = try store.append([window(50, resetsAt: sessionReset), window(45, resetsAt: weekReset, kind: .weekly)],
                         at: base.addingTimeInterval(60))
    _ = try store.append([window(70, resetsAt: sessionReset)], at: base.addingTimeInterval(120))
    let stamp = try #require(try modified(paths))
    // Monday morning: both windows have reset and Claude Code has not answered since.
    try store.compact(now: base.addingTimeInterval(10_000))
    let loaded = try store.load()
    #expect(loaded.map(\.t) == [base.addingTimeInterval(60), base.addingTimeInterval(120)])
    let current = WindowMerge.current(from: loaded)
    #expect(Set(current.map(\.kind)) == [.session, .weekly])
    #expect(current.allSatisfy { $0.isExpired(at: base.addingTimeInterval(10_000)) })
    // A rewrite keeps the time data last arrived.
    #expect(try modified(paths) == stamp)
    // Once a new window arrives, the old one goes at the next compaction.
    _ = try store.append([window(5, resetsAt: base.addingTimeInterval(20_000))], at: base.addingTimeInterval(10_100))
    try store.compact(now: base.addingTimeInterval(10_200))
    #expect(try store.load().map(\.t) == [base.addingTimeInterval(60), base.addingTimeInterval(10_100)])
}

private func appendRaw(_ text: String, to paths: SpoolPaths) throws {
    let handle = try FileHandle(forWritingTo: paths.observations)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

@Test func tailReadReturnsAppendedLinesOnce() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    let missing = try store.load(after: nil)
    #expect(missing.isFull && missing.observations.isEmpty && missing.mark == nil)
    _ = try store.append([window(10)], at: base)
    _ = try store.append([window(20)], at: base.addingTimeInterval(60))
    let first = try store.load(after: nil)
    #expect(first.isFull)
    #expect(first.observations.map { $0.windows[0].usedPercent } == [10, 20])
    _ = try store.append([window(30)], at: base.addingTimeInterval(120))
    let second = try store.load(after: first.mark)
    #expect(!second.isFull)
    #expect(second.observations.map { $0.windows[0].usedPercent } == [30])
    // A repeat moves only the modification time: nothing new to decode.
    _ = try store.append([window(30)], at: base.addingTimeInterval(180))
    let third = try store.load(after: second.mark)
    #expect(!third.isFull && third.observations.isEmpty)
    #expect(third.mark == second.mark)
}

@Test func tailReadReturnsATornLineOnceItIsComplete() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    _ = try store.append([window(10)], at: base)
    let first = try store.load(after: nil)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let line = String(decoding: try encoder.encode(UsageObservation(t: base.addingTimeInterval(60), windows: [window(20)])),
                      as: UTF8.self)
    let cut = line.index(line.startIndex, offsetBy: line.count / 2)
    try appendRaw(String(line[..<cut]), to: paths)
    let torn = try store.load(after: first.mark)
    #expect(!torn.isFull && torn.observations.isEmpty)
    #expect(torn.mark == first.mark)
    try appendRaw(String(line[cut...]) + "\n", to: paths)
    let done = try store.load(after: torn.mark)
    #expect(!done.isFull)
    #expect(done.observations.map { $0.windows[0].usedPercent } == [20])
}

@Test func tailReadNoticesAReplacedOrShrunkFile() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    _ = try store.append([window(50, resetsAt: base.addingTimeInterval(3_600))], at: base)
    _ = try store.append([window(5, resetsAt: base.addingTimeInterval(20_000))], at: base.addingTimeInterval(10_000))
    let before = try store.load(after: nil)
    // Compaction renames a new file over the old one.
    try store.compact(now: base.addingTimeInterval(10_100))
    let replaced = try store.load(after: before.mark)
    #expect(replaced.isFull)
    #expect(try replaced.observations == store.load())
    #expect(replaced.mark != before.mark)
    // Cut short in place: same file, fewer bytes than were read.
    let handle = try FileHandle(forWritingTo: paths.observations)
    try handle.truncate(atOffset: 0)
    try handle.close()
    let shrunk = try store.load(after: replaced.mark)
    #expect(shrunk.isFull && shrunk.observations.isEmpty)
}

@Test func cacheFollowsTheStoreThroughAppendsAndCompaction() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let store = SampleStore(paths: paths)
    var cache = ObservationCache()
    try cache.update(from: store)
    #expect(cache.observations.isEmpty)
    _ = try store.append([window(50, resetsAt: base.addingTimeInterval(3_600))], at: base)
    try cache.update(from: store)
    _ = try store.append([window(60, resetsAt: base.addingTimeInterval(3_600))], at: base.addingTimeInterval(60))
    _ = try store.append([window(5, resetsAt: base.addingTimeInterval(20_000))], at: base.addingTimeInterval(10_000))
    try cache.update(from: store)
    #expect(try cache.observations == store.load())
    #expect(cache.observations.count == 3)
    try store.compact(now: base.addingTimeInterval(10_100))
    try cache.update(from: store)
    #expect(try cache.observations == store.load())
    #expect(cache.observations.count == 1)
}
