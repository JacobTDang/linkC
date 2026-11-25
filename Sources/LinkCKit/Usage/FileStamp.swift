import Darwin
import Foundation

/// What moves whenever a file's content does: its size, its modification time to the nanosecond,
/// and its inode, which a file replaced by a rename does not keep.
struct FileStamp: Equatable, Sendable {
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let inode: UInt64

    /// Nil for a file that is not there. Throws when it is there and cannot be looked at.
    static func of(_ path: String) throws -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw LinkCError.process("\(path) could not be looked at: \(String(cString: strerror(code)))")
        }
        return FileStamp(size: Int64(info.st_size), modifiedSeconds: info.st_mtimespec.tv_sec,
                         modifiedNanoseconds: info.st_mtimespec.tv_nsec, inode: info.st_ino)
    }
}
