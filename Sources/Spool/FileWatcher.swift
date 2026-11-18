import Foundation

/// Calls `onChange` on the main actor whenever the file at `url` is written, extended,
/// deleted or renamed, or its attributes change (a repeated observation only moves the
/// modification time). On delete or rename (the store compacts by renaming a new file over
/// the old one) it reopens the path, creating the file if it is missing, so the watch
/// follows the path rather than the old inode.
///
/// All mutable state is confined to a private serial queue.
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "spool.file-watcher")
    private let debug = ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1"
    private var source: (any DispatchSourceFileSystemObject)?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    // MARK: - Queue-confined

    private func open() {
        source?.cancel()
        source = nil
        let path = url.path
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create the file if missing; never truncate one that exists.
        let create = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        if create >= 0 { close(create) }
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: queue)
        // The handler holds its own source until cancel releases the handler.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if self.debug { FileHandle.standardError.write(Data("watch: \(Self.describe(events))\n".utf8)) }
            if events.contains(.delete) || events.contains(.rename) {
                self.open()
            }
            self.notify()
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private static func describe(_ events: DispatchSource.FileSystemEvent) -> String {
        let names: [(DispatchSource.FileSystemEvent, String)] = [
            (.write, "write"), (.extend, "extend"), (.attrib, "attrib"), (.delete, "delete"), (.rename, "rename"),
        ]
        return names.filter { events.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    private func notify() {
        let onChange = onChange
        Task { @MainActor in onChange() }
    }
}
