import Foundation

public struct UsageObservation: Codable, Hashable, Sendable {
    public var t: Date
    public var windows: [LimitWindow]

    public init(t: Date, windows: [LimitWindow]) {
        self.t = t
        self.windows = windows
    }
}

public struct SampleStore: Sendable {
    private let paths: SpoolPaths

    /// Bytes read per step when looking for the last line from the end of the file.
    static let tailChunk = 16_384

    public init(paths: SpoolPaths) {
        self.paths = paths
    }

    /// Appends one observation line unless it matches the last stored one. A repeat writes
    /// nothing and only moves the file's modification time forward to `t`, so the app can show
    /// when data last arrived. Returns whether a line was written.
    public func append(_ windows: [LimitWindow], at t: Date) throws -> Bool {
        try withLock {
            let fd = open(paths.observations.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw SpoolError.io("cannot open \(paths.observations.path): errno \(errno)") }
            defer { close(fd) }
            let size = try Self.size(of: fd)
            if let last = try Self.lastObservation(fd: fd, size: size),
               Self.signature(last.windows) == Self.signature(windows) {
                try Self.moveModificationTime(of: fd, forwardTo: t)
                return false
            }
            var line = Data()
            // An interrupted write can leave a line without its newline; end it first, so it
            // does not swallow this one.
            if size > 0, try Self.byte(of: fd, at: size - 1) != 0x0A { line.append(0x0A) }
            line.append(try Self.encoder().encode(UsageObservation(t: t, windows: windows)))
            line.append(0x0A)
            try Self.write(line, to: fd)
            return true
        }
    }

    /// Reads all valid observations; corrupt lines are skipped.
    public func load() throws -> [UsageObservation] {
        try readAll()
    }

    /// Which observations file a reader has read, and how far.
    public struct ReadMark: Equatable, Sendable {
        fileprivate var device: dev_t
        fileprivate var inode: ino_t
        /// Bytes read: through the end of the last complete line.
        fileprivate var offset: Int
    }

    /// What `load(after:)` read.
    public struct TailRead: Sendable {
        /// The observations are the whole file, not an addition: there was no mark, or the file
        /// was replaced (compaction renames a new one over it) or is shorter than the mark.
        public var isFull: Bool
        /// Valid observations in the bytes read; corrupt lines are skipped as in `load()`.
        public var observations: [UsageObservation]
        /// Where the next read starts; nil while there is no file.
        public var mark: ReadMark?
    }

    /// Reads only what was appended after `mark`, so a watcher event costs the new lines, not
    /// the whole history. Complete lines only: a line still being written is returned by the
    /// read after it ends, which is why no lock is needed: a reader on the main thread never
    /// waits for the helper.
    public func load(after mark: ReadMark?) throws -> TailRead {
        let fd = open(paths.observations.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return TailRead(isFull: true, observations: [], mark: nil) }
            throw SpoolError.io("cannot open \(paths.observations.path): errno \(errno)")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SpoolError.io("fstat failed: errno \(errno)") }
        let size = Int(info.st_size)
        var resumeAt: Int?
        if let mark, mark.device == info.st_dev, mark.inode == info.st_ino, mark.offset <= size {
            resumeAt = mark.offset
        }
        let start = resumeAt ?? 0
        let bytes = size > start ? try Self.read(fd, count: size - start, at: start) : []
        let end = bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let decoder = Self.decoder()
        let observations = bytes[..<end].split(separator: 0x0A)
            .compactMap { try? decoder.decode(UsageObservation.self, from: Data($0)) }
        return TailRead(isFull: resumeAt == nil, observations: observations,
                        mark: ReadMark(device: info.st_dev, inode: info.st_ino, offset: start + end))
    }

    /// The modification time of the observations file: the time the newest line was written,
    /// or a later repeat of it. Nil without a file.
    public func lastModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.observations.path))?[.modificationDate] as? Date
    }

    /// Drops observations whose windows have all expired at `now`, except the newest
    /// observation of each (provider, kind): a window that has reset keeps showing as reset
    /// (nothing used) until new data arrives. When nothing is dropped the file is left alone;
    /// a rewrite keeps the file's modification time.
    public func compact(now: Date) throws {
        try withLock {
            let all = try readAll()
            let kept = Self.retained(all, now: now)
            guard kept.count < all.count else { return }
            var data = Data()
            let encoder = Self.encoder()
            for obs in kept {
                data.append(try encoder.encode(obs))
                data.append(0x0A)
            }
            var original = stat()
            let hasOriginal = stat(paths.observations.path, &original) == 0
            let tmp = paths.directory.appendingPathComponent("observations.jsonl.\(UUID().uuidString).tmp")
            do {
                try data.write(to: tmp)
                if hasOriginal {
                    var times = [original.st_atimespec, original.st_mtimespec]
                    if utimensat(AT_FDCWD, tmp.path, &times, 0) != 0 {
                        throw SpoolError.io("cannot keep modification time: errno \(errno)")
                    }
                }
                if rename(tmp.path, paths.observations.path) != 0 {
                    throw SpoolError.io("rename failed: errno \(errno)")
                }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
        }
    }

    /// The last valid observation, as `load().last` would return it, read from the end of
    /// the file only.
    func lastObservation() throws -> UsageObservation? {
        try withLock {
            let fd = open(paths.observations.path, O_RDONLY | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { return nil }
                throw SpoolError.io("cannot open \(paths.observations.path): errno \(errno)")
            }
            defer { close(fd) }
            return try Self.lastObservation(fd: fd, size: Self.size(of: fd))
        }
    }

    // MARK: - Internals

    /// What makes two observations the same for dedupe. The reset time counts in whole seconds:
    /// resets fall on whole seconds, and a date with fractional seconds (from the OAuth source)
    /// can come back one ulp off through `secondsSince1970`. The source counts: the app shows or
    /// hides each source's windows on its own, so equal numbers from another source still count
    /// as that source's data.
    private struct Key: Hashable {
        var provider: Provider
        var kind: WindowKind
        var source: DataSource
        var usedPercent: Double
        var resetsAt: Int64
    }

    private static func signature(_ windows: [LimitWindow]) -> Set<Key> {
        Set(windows.map {
            Key(provider: $0.provider, kind: $0.kind, source: $0.source, usedPercent: $0.usedPercent,
                resetsAt: Int64($0.resetsAt.timeIntervalSince1970.rounded()))
        })
    }

    /// Observations with a window still running, plus the newest observation (in file order)
    /// of each (provider, kind).
    static func retained(_ all: [UsageObservation], now: Date) -> [UsageObservation] {
        struct Group: Hashable { var provider: Provider; var kind: WindowKind }
        var newest: [Group: Int] = [:]
        for (index, obs) in all.enumerated() {
            for window in obs.windows { newest[Group(provider: window.provider, kind: window.kind)] = index }
        }
        let pinned = Set(newest.values)
        return all.indices
            .filter { pinned.contains($0) || all[$0].windows.contains { !$0.isExpired(at: now) } }
            .map { all[$0] }
    }

    /// Walks back from the end of the file in `tailChunk` steps, line by line, and returns the
    /// first line that decodes. Corrupt lines (a torn tail included) are skipped as in `readAll`.
    private static func lastObservation(fd: Int32, size: Int) throws -> UsageObservation? {
        let decoder = decoder()
        func decode(_ line: ArraySlice<UInt8>) -> UsageObservation? {
            line.isEmpty ? nil : try? decoder.decode(UsageObservation.self, from: Data(line))
        }
        var buffer: [UInt8] = []
        var start = size
        while true {
            if let newline = buffer.lastIndex(of: 0x0A) {
                let line = buffer[(newline + 1)...]
                if let obs = decode(line) { return obs }
                buffer.removeSubrange(newline...)
            } else if start == 0 {
                return decode(buffer[...])
            } else {
                let count = min(tailChunk, start)
                start -= count
                buffer = try read(fd, count: count, at: start) + buffer
            }
        }
    }

    private static func size(of fd: Int32) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SpoolError.io("fstat failed: errno \(errno)") }
        return Int(info.st_size)
    }

    private static func read(_ fd: Int32, count: Int, at offset: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = bytes.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + done, count - done, off_t(offset + done))
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw SpoolError.io("read failed: errno \(errno)") }
            done += n
        }
        return bytes
    }

    private static func byte(of fd: Int32, at offset: Int) throws -> UInt8 {
        try read(fd, count: 1, at: offset)[0]
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + done, buffer.count - done)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw SpoolError.io("write failed: errno \(errno)") }
                done += n
            }
        }
    }

    /// Sets the file's access and modification times to `t` unless it was modified later.
    private static func moveModificationTime(of fd: Int32, forwardTo t: Date) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SpoolError.io("fstat failed: errno \(errno)") }
        let current = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        let target = t.timeIntervalSince1970
        guard target > current else { return }
        let seconds = target.rounded(.down)
        let stamp = timespec(tv_sec: Int(seconds), tv_nsec: Int(((target - seconds) * 1e9).rounded(.down)))
        var times = [stamp, stamp]
        guard futimens(fd, &times) == 0 else { throw SpoolError.io("futimens failed: errno \(errno)") }
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func readAll() throws -> [UsageObservation] {
        guard FileManager.default.fileExists(atPath: paths.observations.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: paths.observations) } catch { throw SpoolError.io("\(error)") }
        let decoder = Self.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(UsageObservation.self, from: Data($0)) }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        } catch {
            throw SpoolError.io("\(error)")
        }
        let fd = open(paths.lock.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw SpoolError.io("cannot open lock: errno \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SpoolError.io("flock failed: errno \(errno)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// The store's observations kept in memory and brought up to date with `SampleStore.load(after:)`.
public struct ObservationCache: Sendable {
    public private(set) var observations: [UsageObservation] = []
    private var mark: SampleStore.ReadMark?

    public init() {}

    /// Adds what was appended since the last update, or reloads a replaced file. After a failed
    /// read the cache keeps what it had.
    public mutating func update(from store: SampleStore) throws {
        let read = try store.load(after: mark)
        if read.isFull {
            observations = read.observations
        } else {
            observations += read.observations
        }
        mark = read.mark
    }
}
