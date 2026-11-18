import Foundation

/// What `stat(2)` says about a file: enough to tell that it changed without reading it.
public struct FileStamp: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t
    var size: off_t
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int

    /// Nil when there is no file at `path`; a symbolic link is followed.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}
