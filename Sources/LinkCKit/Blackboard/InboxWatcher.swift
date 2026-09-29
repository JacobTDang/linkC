import Foundation
import Darwin

/// Calls `onChange` when a watched workspace's `.linkc/inbox.json` is replaced. Every inbox save
/// writes a temporary file and renames it over `inbox.json`, so the watch is on the `.linkc`
/// folder's entries (kqueue through a dispatch source) and each folder event is checked against
/// the inbox file's identity: a write to anything else in `.linkc` (the blackboard, a lock file,
/// a temporary that has not been renamed yet) stays quiet. An in-place edit that renames nothing
/// is not seen; the next tick of the sweep reads it.
///
/// A workspace with no `.linkc` folder yet is watched one level up, for the folder to appear; a
/// workspace that cannot be opened is retried on every `watch(workspaces:)`. `onChange` runs on
/// the watcher's own queue and can fire more than once per save: callers only wake a loop.
public final class InboxWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    /// Owns every source, descriptor and the state below; only this queue touches them.
    private let queue = DispatchQueue(label: "linkc.inbox-watcher")
    private var watches: [String: Watch] = [:]
    private var stopped = false
    /// Paths whose open failed for a reason other than "does not exist", logged once each.
    private var reported: Set<String> = []

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // No other thread can hold `self` here, so the sources can be cancelled inline. A
        // `queue.sync` would deadlock when the last reference is dropped from inside an event
        // handler, which is already running on `queue`.
        for watch in watches.values { watch.cancel() }
    }

    /// Makes `workspaces` (canonical paths) the set being watched: starts on new ones, drops the
    /// rest, and retries any that could not be attached before. Cheap enough to call every tick.
    public func watch(workspaces: Set<String>) {
        queue.sync { [self] in
            guard !stopped else { return }
            for (path, watch) in watches where !workspaces.contains(path) {
                watch.cancel()
                watches[path] = nil
            }
            for path in workspaces {
                if let existing = watches[path] {
                    attach(existing)
                } else {
                    let watch = Watch(root: path)
                    watches[path] = watch
                    attach(watch)
                    watch.inbox = Self.signature(ofFileAt: watch.inboxPath)
                }
            }
        }
    }

    /// Ends every watch. Idempotent; later `watch(workspaces:)` calls do nothing.
    public func stop() {
        queue.sync { [self] in
            stopped = true
            for watch in watches.values { watch.cancel() }
            watches = [:]
        }
    }

    // MARK: - Confined to `queue`

    private final class Watch {
        let root: String
        /// The `.linkc` folder's entries, once it exists.
        var folder: DispatchSourceFileSystemObject?
        /// The workspace folder's entries, while `.linkc` does not exist yet.
        var parent: DispatchSourceFileSystemObject?
        /// The inbox file as last seen, so an event that left it alone can be told from one that did not.
        var inbox: FileSignature?

        init(root: String) { self.root = root }

        var folderPath: String { (root as NSString).appendingPathComponent(".linkc") }
        var inboxPath: String { (folderPath as NSString).appendingPathComponent("inbox.json") }

        func cancel() {
            folder?.cancel()
            folder = nil
            parent?.cancel()
            parent = nil
        }
    }

    private struct FileSignature: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private static func signature(ofFileAt path: String) -> FileSignature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileSignature(
            inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    /// Watches `.linkc` if it exists; otherwise the workspace folder, until it does.
    private func attach(_ watch: Watch) {
        guard watch.folder == nil else { return }
        if attachFolder(watch) { return }
        if watch.parent == nil {
            watch.parent = openSource(at: watch.root, mask: .write) { [weak self, weak watch] _ in
                guard let self, let watch else { return }
                parentChanged(watch)
            }
            // `.linkc` may have been made between the failed open above and the parent watch
            // starting, and nothing would ever say so.
            if watch.parent != nil, attachFolder(watch) { check(watch) }
        }
    }

    private func attachFolder(_ watch: Watch) -> Bool {
        guard let source = openSource(at: watch.folderPath, mask: [.write, .delete, .rename], handler: { [weak self, weak watch] event in
            guard let self, let watch else { return }
            folderChanged(watch, event: event)
        }) else { return false }
        watch.folder = source
        watch.parent?.cancel()
        watch.parent = nil
        return true
    }

    private func parentChanged(_ watch: Watch) {
        guard watch.folder == nil, attachFolder(watch) else { return }
        check(watch)
    }

    private func folderChanged(_ watch: Watch, event: DispatchSource.FileSystemEvent) {
        if event.contains(.delete) || event.contains(.rename) {
            // The folder itself went; what is at the path now (if anything) is a different one.
            watch.folder?.cancel()
            watch.folder = nil
            attach(watch)
        }
        check(watch)
    }

    /// Fires when the inbox file is not the one last seen.
    private func check(_ watch: Watch) {
        let current = Self.signature(ofFileAt: watch.inboxPath)
        guard current != watch.inbox else { return }
        watch.inbox = current
        onChange()
    }

    private func openSource(
        at path: String, mask: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor != -1 else {
            let failure = errno
            if failure != ENOENT, reported.insert(path).inserted {
                NSLog("[linkC relay] inbox watch: could not watch %@ — %@; its inbox is read on the sweep only",
                      path, String(cString: strerror(failure)))
            }
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
