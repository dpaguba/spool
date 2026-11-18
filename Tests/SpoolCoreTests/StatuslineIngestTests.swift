import Foundation
import Testing
@testable import SpoolCore

private func tempPaths() -> SpoolPaths {
    SpoolPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func writeChain(_ state: ChainState, to paths: SpoolPaths) throws {
    try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: paths.chainState)
}

@Test func validPayloadIsRecordedSilently() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let out = StatuslineIngest.run(stdin: try fixture("statusline"), paths: paths, now: now)
    #expect(out.isEmpty)
    #expect(try SampleStore(paths: paths).load().count == 1)
}

@Test func repeatIsDeduped() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let data = try fixture("statusline")
    _ = StatuslineIngest.run(stdin: data, paths: paths, now: now)
    _ = StatuslineIngest.run(stdin: data, paths: paths, now: now.addingTimeInterval(60))
    #expect(try SampleStore(paths: paths).load().count == 1)
}

@Test func repeatedPayloadMovesTheModificationTime() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let data = try fixture("statusline")
    _ = StatuslineIngest.run(stdin: data, paths: paths, now: now)
    let bytes = try Data(contentsOf: paths.observations)
    let later = now.addingTimeInterval(90)
    _ = StatuslineIngest.run(stdin: data, paths: paths, now: later)
    #expect(try Data(contentsOf: paths.observations) == bytes)
    #expect(SampleStore(paths: paths).lastModified() == later)
}

@Test func nullLimitsWriteNothing() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let out = StatuslineIngest.run(stdin: try fixture("statusline-no-limits"), paths: paths, now: now)
    #expect(out.isEmpty)
    #expect(try SampleStore(paths: paths).load().isEmpty)
}

@Test(arguments: [Data("\u{0}garbage".utf8), Data()])
func garbageWritesNothing(input: Data) throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let out = StatuslineIngest.run(stdin: input, paths: paths, now: now)
    #expect(out.isEmpty)
    #expect(try SampleStore(paths: paths).load().isEmpty)
}

@Test func chainedCommandOutputIsPassedThrough() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    try writeChain(ChainState(previousCommand: "cat >/dev/null; printf 'hello'"), to: paths)
    let out = StatuslineIngest.run(stdin: try fixture("statusline"), paths: paths, now: now)
    #expect(String(decoding: out, as: UTF8.self) == "hello")
    #expect(try SampleStore(paths: paths).load().count == 1)
}

@Test func failingChainedCommandGivesEmpty() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    try writeChain(ChainState(previousCommand: "exit 3"), to: paths)
    let out = StatuslineIngest.run(stdin: try fixture("statusline"), paths: paths, now: now)
    #expect(out.isEmpty)
}

@Test func chainedCommandSeesItIsChained() {
    let out = ChainRunner.run(command: "printf %s \"$SPOOL_STATUSLINE_CHAINED\"", input: Data())
    #expect(String(decoding: out, as: UTF8.self) == "1")
}

@Test func helperRunByAChainedCommandDoesNothing() throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    try writeChain(ChainState(previousCommand: "cat >/dev/null; printf 'hello'"), to: paths)
    let out = StatuslineIngest.run(stdin: try fixture("statusline"), paths: paths, now: now,
                                   environment: ["SPOOL_STATUSLINE_CHAINED": "1"])
    #expect(out.isEmpty)
    #expect(try SampleStore(paths: paths).load().isEmpty)
}

@Test func productionLimitsAreTheDefaults() {
    #expect(ChainRunner.timeout == .seconds(5))
    #expect(ChainRunner.outputLimit == 65_536)
}

@Test func hangingChainedCommandIsCutOff() {
    let start = ContinuousClock.now
    let out = ChainRunner.run(command: "sleep 3", input: Data("{}".utf8), timeout: .milliseconds(500))
    #expect(out.isEmpty)
    #expect(ContinuousClock.now - start < .milliseconds(1_500))
}

@Test func backgroundProcessHoldingTheOutputIsNotAwaited() {
    // Neither the background process (2 s) nor the deadline (1.5 s) is waited for.
    let start = ContinuousClock.now
    let out = ChainRunner.run(command: "(sleep 2 &); printf ok", input: Data("{}".utf8), timeout: .milliseconds(1_500))
    #expect(String(decoding: out, as: UTF8.self) == "ok")
    #expect(ContinuousClock.now - start < .milliseconds(500))
}

@Test func endlessOutputStopsAtTheCap() {
    let start = ContinuousClock.now
    let out = ChainRunner.run(command: "yes", input: Data("{}".utf8))
    #expect(out.count == 65_536)
    #expect(out.prefix(4) == Data("y\ny\n".utf8))
    #expect(ContinuousClock.now - start < .seconds(1))
}

@Test func outputAfterTheCommandExitedIsCappedToo() {
    // The command exits at once; a background process keeps writing into the same pipe.
    let start = ContinuousClock.now
    let out = ChainRunner.run(command: "(yes &); exit 0", input: Data("{}".utf8))
    #expect(out.count <= 65_536)
    #expect(ContinuousClock.now - start < .seconds(1))
}

@Test func outputLimitKeepsTheFirstBytes() {
    #expect(ChainRunner.run(command: "printf 0123456789", input: Data(), outputLimit: 4) == Data("0123".utf8))
}

@Test func largeInputAndOutputPassThroughUnchanged() {
    // More than a pipe holds in both directions at once (above the production output cap).
    let input = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
    #expect(ChainRunner.run(command: "cat", input: input, outputLimit: 1_000_000) == input)
    let out = ChainRunner.run(command: "cat >/dev/null; head -c 200000 /dev/zero | tr '\\0' x", input: input,
                              outputLimit: 1_000_000)
    #expect(out == Data(repeating: UInt8(ascii: "x"), count: 200_000))
}

@Test func childThatIgnoresItsInputRaisesNoSIGPIPE() {
    // Left at the default disposition, SIGPIPE would end the test process here.
    let out = ChainRunner.run(command: "exit 0", input: Data(count: 1_000_000))
    #expect(out.isEmpty)
}
