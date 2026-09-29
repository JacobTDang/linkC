import Foundation

/// Hears each Claude session's status line without a process for it. The status-line command
/// (`SettingsComposer.statusLineCommand`) is shell builtins that write Claude's status JSON into a
/// file, one per session; this watches those files through kqueue and hands each complete report
/// on. Nothing is polled: a session that reports nothing costs nothing.
///
/// Everything below runs on one serial queue, including `deliver` and `log`: keep them quick.
public final class StatusLineFeed: @unchecked Sendable {
    public typealias Deliver = @Sendable (_ body: Data, _ reading: AgentUsage) -> Void

    /// One session's watched file. Touched only on `queue`.
    private final class Watch: @unchecked Sendable {
        let url: URL
        let source: DispatchSourceFileSystemObject
        /// Bumped by every file event, so a retry scheduled before it knows the event has read
        /// the file since and does nothing: one report is delivered once.
        var epoch = 0
        /// Reads since the last event that found the file empty or torn.
        var attempts = 0
        /// The last failure logged for this file. Cleared by a good report, so a failure that
        /// comes back after one is news again, while the same failure on every refresh is not.
        var lastFailure: String?
        /// The body of the last report delivered from this file.
        var lastDelivered: Data?

        init(url: URL, source: DispatchSourceFileSystemObject) {
            self.url = url
            self.source = source
        }
    }

    private static let fileExtension = "line"

    private let directory: URL
    private let deliver: Deliver
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let read: @Sendable (URL, Date) -> StatusLineFile.Outcome
    private let retryDelay: TimeInterval
    private let maxRetries: Int
    private let queue = DispatchQueue(label: "com.linkc.status-line-feed")
    private var watches: [String: Watch] = [:]

    /// - Parameters:
    ///   - directory: where each session's file lives; created on the first `watch`.
    ///   - deliver: called with each report that carries rate limits.
    ///   - log: where a failure to hear a session is said, once per change.
    ///   - retryDelay: how long to wait before reading again after finding the file empty or torn.
    ///   - maxRetries: how many times to read again before calling that a failure. The write the
    ///     command is in the middle of also raises its own event, so a retry that gives up early
    ///     costs nothing but a log line.
    public init(
        directory: URL,
        deliver: @escaping Deliver,
        now: @escaping @Sendable () -> Date = Date.init,
        log: @escaping @Sendable (String) -> Void = { NSLog("[linkC] %@", $0) },
        read: @escaping @Sendable (URL, Date) -> StatusLineFile.Outcome = StatusLineFile.read(at:receivedAt:),
        retryDelay: TimeInterval = 0.05,
        maxRetries: Int = 5
    ) {
        self.directory = directory
        self.deliver = deliver
        self.now = now
        self.log = log
        self.read = read
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
    }

    deinit {
        for watch in watches.values { watch.source.cancel() }
    }

    /// Where `sessionId`'s status file is, or would be: the path its status-line command is given.
    public func fileURL(sessionId: String) -> URL {
        directory.appendingPathComponent("\(sessionId).\(Self.fileExtension)")
    }

    /// Creates `sessionId`'s status file empty, private to the user, and watches it before this
    /// returns; the status-line command may write it from then on. Watching a session again starts
    /// its file empty.
    @discardableResult
    public func watch(sessionId: String) throws -> URL {
        try queue.sync {
            stopWatching(sessionId)
            return try arm(sessionId, keepingContent: false).url
        }
    }

    /// Stops watching `sessionId` and removes its file. Idempotent.
    public func unwatch(sessionId: String) {
        queue.sync {
            stopWatching(sessionId)
            remove(fileURL(sessionId: sessionId))
        }
    }

    /// Stops watching every session and removes their files, and any file no running feed holds:
    /// one a crashed run left behind. The folder is shared with every other linkC that runs (a dev
    /// build beside the installed app), so a file another running feed watches is left alone.
    public func sweep() {
        queue.sync {
            for id in Array(watches.keys) {
                stopWatching(id)
                remove(fileURL(sessionId: id))
            }
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            do {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == Self.fileExtension {
                    removeUnlessHeld(file)
                }
            } catch {
                log("could not list the status line folder \(directory.path) — \(error)")
            }
        }
    }

    // MARK: - Confined to `queue`

    /// Makes the folder and `sessionId`'s file when they are missing, the file private to the user,
    /// and starts watching it. The watch descriptor also holds a shared lock on the file: that is
    /// how `sweep` in another process tells a live file from a leftover, and the system drops the
    /// lock when this process ends, however it ends. The descriptor is close-on-exec, so a session
    /// forked later does not inherit the file (or the lock) and keep it past this process.
    /// A file already there keeps what it holds when `keepingContent`, and is emptied otherwise.
    private func arm(_ sessionId: String, keepingContent: Bool) throws -> Watch {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(sessionId: sessionId)
        if keepingContent && FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw LinkCError.server("could not create the status line file \(url.path)")
        }
        let descriptor = try Self.openLocked(url)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        let watch = Watch(url: url, source: source)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            changed(sessionId, watch, source.data)
        }
        source.setCancelHandler { close(descriptor) }
        watches[sessionId] = watch
        source.resume()
        return watch
    }

    /// Opens `url` for watching and takes the shared lock that marks it live. A `sweep` in another
    /// process can unlink the file between the open and the lock; the lock would then hold a file
    /// no path reaches and the watch would never fire, so the file is made again (private, empty)
    /// and opened afresh until the locked descriptor is the file at the path.
    /// `beforeLocking` runs between the open and the lock, so a test can remove the file there.
    static func openLocked(_ url: URL, beforeLocking: () -> Void = {}) throws -> Int32 {
        for _ in 0..<3 {
            if !FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
                throw LinkCError.server("could not create the status line file \(url.path)")
            }
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor != -1 else {
                throw LinkCError.server("could not watch \(url.path): \(String(cString: strerror(errno)))")
            }
            beforeLocking()
            guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                let message = String(cString: strerror(errno))
                close(descriptor)
                throw LinkCError.server("could not lock \(url.path): \(message)")
            }
            var opened = stat(), atPath = stat()
            if fstat(descriptor, &opened) == 0, stat(url.path, &atPath) == 0,
               opened.st_dev == atPath.st_dev, opened.st_ino == atPath.st_ino {
                return descriptor
            }
            close(descriptor)
        }
        throw LinkCError.server("could not watch \(url.path): it was removed each time it was opened")
    }

    private func stopWatching(_ sessionId: String) {
        watches.removeValue(forKey: sessionId)?.source.cancel()
    }

    private func removeUnlessHeld(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor != -1 else {
            if errno != ENOENT { log("could not open the status line file \(url.path): \(String(cString: strerror(errno)))") }
            return
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno != EWOULDBLOCK { log("could not lock the status line file \(url.path): \(String(cString: strerror(errno)))") }
            return
        }
        remove(url)
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            log("could not remove the status line file \(url.path) — \(error)")
        }
    }

    private func changed(_ sessionId: String, _ watch: Watch, _ event: DispatchSource.FileSystemEvent) {
        guard watches[sessionId] === watch else { return }
        if event.contains(.delete) || event.contains(.rename) {
            rearm(sessionId, watch)
            return
        }
        watch.epoch += 1
        watch.attempts = 0
        check(sessionId, watch)
    }

    /// The file this watch holds was removed or moved. The command's `>` makes its file again the
    /// next time it runs, at the same path and open to other users, and nothing would be watching
    /// it: make the file (or take the one that is there) and watch that. A report the command
    /// already wrote into it is read now, since it raised its event before anyone was watching.
    private func rearm(_ sessionId: String, _ old: Watch) {
        stopWatching(sessionId)
        let watch: Watch
        do {
            watch = try arm(sessionId, keepingContent: true)
        } catch {
            log("the status line file \(old.url.path) was removed or replaced and could not be watched again — this session's usage is no longer heard: \(error)")
            return
        }
        log("the status line file \(old.url.path) was removed or replaced — watching the file now at that path")
        check(sessionId, watch, mayBeEmpty: true)
    }

    private func check(_ sessionId: String, _ watch: Watch, mayBeEmpty: Bool = false) {
        guard watches[sessionId] === watch else { return }
        switch read(watch.url, now()) {
        case .report(let body, let reading):
            watch.attempts = 0
            watch.lastFailure = nil
            // One write can raise two events, and each finds the whole file: a report the same as
            // the last delivered is that write read again.
            if let reading, body != watch.lastDelivered {
                watch.lastDelivered = body
                deliver(body, reading)
            }
        case .empty:
            guard !mayBeEmpty else { return }
            readAgainOrFail(sessionId, watch, "the status line file \(watch.url.path) was emptied and nothing was written into it")
        case .torn:
            readAgainOrFail(sessionId, watch, "the status line file \(watch.url.path) still ends mid-line after \(maxRetries) more reads")
        case .unreadable(let message), .garbage(let message):
            fail(watch, message)
        }
    }

    private func readAgainOrFail(_ sessionId: String, _ watch: Watch, _ failure: String) {
        guard watch.attempts >= maxRetries else {
            watch.attempts += 1
            let epoch = watch.epoch
            queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard watch.epoch == epoch else { return }
                self?.check(sessionId, watch)
            }
            return
        }
        fail(watch, failure)
    }

    private func fail(_ watch: Watch, _ failure: String) {
        guard watch.lastFailure != failure else { return }
        watch.lastFailure = failure
        log(failure)
    }
}
