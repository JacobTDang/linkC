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

    /// A file's bytes and the identity of the file they were read from.
    struct Contents: Sendable {
        let identity: FileIdentity
        let data: Data
    }

    let device: dev_t
    let inode: ino_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let size: off_t

    private init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        size = info.st_size
    }

    /// What `path` is right now, to compare with the identity of bytes read earlier. It says
    /// nothing about bytes: to read a file and know what it was, use `read`.
    /// `.missing` only for a file (or a directory above it) that is not there. Any other failure to
    /// stat is thrown: reporting it as "no file" would read as an empty inbox.
    static func probe(_ path: String) throws -> Probe {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let failure = errno
            if failure == ENOENT || failure == ENOTDIR { return .missing }
            throw LinkCError.server("Failed to stat \(path): errno \(failure)")
        }
        return .present(FileIdentity(info))
    }

    /// The contents of `path` and the identity of the file they came from, or nil for a file (or a
    /// directory above it) that is not there. Opens the file once and both stats and reads that
    /// descriptor, so a rename over `path` at any moment cannot pair one file's identity with
    /// another's bytes. The identity is taken before the bytes are read: a rewrite in between then
    /// makes the next probe differ and costs one extra read, where stat-ing after would pair an old
    /// file's bytes with the new identity and serve them for as long as it held. Any other failure
    /// to open, stat or read is thrown.
    /// `beforeReading` runs between the two, so a test can change the path at exactly that moment.
    static func read(_ path: String, beforeReading: () -> Void = {}) throws -> Contents? {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            let failure = errno
            if failure == ENOENT || failure == ENOTDIR { return nil }
            throw LinkCError.server("Failed to open \(path): errno \(failure)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw LinkCError.server("Failed to stat \(path): errno \(errno)")
        }
        let identity = FileIdentity(info)
        beforeReading()
        return Contents(identity: identity, data: try handle.readToEnd() ?? Data())
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
///
/// Holds at most `capacity` inboxes, dropping the least recently used: a long-running app reads
/// workspaces it will never look at again, and each entry is a whole decoded inbox.
final class InboxReadCache: Sendable {
    /// Well above the workspaces a relay tick touches, so steady state never evicts; a workspace
    /// evicted anyway only costs one read the next time it is asked about.
    static let defaultCapacity = 64

    static let shared = InboxReadCache()

    private struct Entry: Sendable {
        let identity: FileIdentity
        let inbox: Inbox
        var lastUse: UInt64
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        /// Bumped on every store and hit; the entry with the smallest `lastUse` is the coldest.
        var useCount: UInt64 = 0
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = InboxReadCache.defaultCapacity) {
        self.capacity = capacity
    }

    /// The cached inbox for `path`, if it was read from a file with exactly this identity.
    func inbox(at path: String, matching identity: FileIdentity) -> Inbox? {
        state.withLock { state in
            guard let entry = state.entries[path], entry.identity == identity else { return nil }
            state.useCount += 1
            state.entries[path]?.lastUse = state.useCount
            return entry.inbox
        }
    }

    /// `identity` is the one `FileIdentity.read` returned with the bytes `inbox` was decoded from.
    func store(_ inbox: Inbox, at path: String, identity: FileIdentity) {
        state.withLock { state in
            state.useCount += 1
            state.entries[path] = Entry(identity: identity, inbox: inbox, lastUse: state.useCount)
            if state.entries.count > capacity,
               let coldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                state.entries.removeValue(forKey: coldest.key)
            }
        }
    }

    func forget(path: String) {
        state.withLock { _ = $0.entries.removeValue(forKey: path) }
    }
}
