import Foundation

public struct SpoolPaths: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> SpoolPaths {
        if let override = ProcessInfo.processInfo.environment["SPOOL_DATA_DIR"], !override.isEmpty {
            return SpoolPaths(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return SpoolPaths(directory: support.appendingPathComponent("Spool", isDirectory: true))
    }

    public var observations: URL { directory.appendingPathComponent("observations.jsonl") }
    public var lock: URL { directory.appendingPathComponent("observations.lock") }
    public var chainState: URL { directory.appendingPathComponent("chain.json") }
    public var thresholds: URL { directory.appendingPathComponent("thresholds.json") }
    public var fetchGates: URL { directory.appendingPathComponent("fetch-gates.json") }
    public var backups: URL { directory.appendingPathComponent("backups", isDirectory: true) }
}
