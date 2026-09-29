import Foundation
import Darwin
import os

/// What the filesystem says a file is right now. Two probes that are equal mean the file was not
/// replaced (a new inode) or rewritten (a new modification time or size) in between.
/// `InboxStore` writes by renaming a temp file over `inbox.json`, so every save from linkC or
/// `linkc-mcp` changes the inode; the modification time (nanoseconds) and size catch an editor
/// that rewrites the file in place.
struct FileIdentity: Equatable, Sendable {
    enum Probe: Equatable, Sendable {
        case missing
        case present(FileIdentity)
    }

    let device: dev_t
    let inode: ino_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let size: off_t

    /// `.missing` only for a file (or a directory above it) that is not there. Any other failure to
    /// stat is thrown: reporting it as "no file" would read as an empty inbox.
    static func probe(_ path: String) throws -> Probe {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let failure = errno
            if failure == ENOENT || failure == ENOTDIR { return .missing }
            throw LinkCError.server("Failed to stat \(path): errno \(failure)")
        }
        return .present(FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            size: info.st_size
        ))
    }
}

/// The last decoded `inbox.json` per path, valid for exactly the file identity it was read at.
///
/// The relay asks read-only questions of the same file many times a tick, and `InboxStore` is
/// constructed fresh for nearly every call, so the cache is process-wide. It only ever answers
/// read-only questions: `InboxStore`'s read-modify-write calls read the file from disk under the
/// lock, because another process (`linkc-mcp`) may have written since. A cached copy is served
/// only while the file still has the identity it was read at, so any save by anyone — an atomic
/// rename gives the file a new inode — makes the next read go back to disk.
final class InboxReadCache: Sendable {
    static let shared = InboxReadCache()

    private struct Entry: Sendable {
        let identity: FileIdentity
        let inbox: Inbox
    }

    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// The cached inbox for `path`, if it was read from a file with exactly this identity.
    func inbox(at path: String, matching identity: FileIdentity) -> Inbox? {
        entries.withLock { cache in
            guard let entry = cache[path], entry.identity == identity else { return nil }
            return entry.inbox
        }
    }

    /// `identity` must be probed BEFORE the file was read: a file replaced in between then makes
    /// the next probe differ and costs one extra read, where probing after would pair an old
    /// identity's content with the new file's and serve it forever.
    func store(_ inbox: Inbox, at path: String, identity: FileIdentity) {
        entries.withLock { $0[path] = Entry(identity: identity, inbox: inbox) }
    }

    func forget(path: String) {
        entries.withLock { _ = $0.removeValue(forKey: path) }
    }
}
