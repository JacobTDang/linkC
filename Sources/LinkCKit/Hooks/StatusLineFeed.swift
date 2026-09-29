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

        init(url: URL, source: DispatchSourceFileSystemObject) {
            self.url = url
            self.source = source
        }
    }

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
        directory.appendingPathComponent("\(sessionId).line")
    }

    /// Creates `sessionId`'s status file empty, private to the user, and watches it before this
    /// returns; the status-line command may write it from then on. Watching a session again starts
    /// its file empty.
    @discardableResult
    public func watch(sessionId: String) throws -> URL {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(sessionId: sessionId)
            stopWatching(sessionId)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LinkCError.server("could not create the status line file \(url.path)")
            }
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor != -1 else {
                throw LinkCError.server("could not watch \(url.path): \(String(cString: strerror(errno)))")
            }
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
            return url
        }
    }

    /// Stops watching `sessionId` and removes its file. Idempotent.
    public func unwatch(sessionId: String) {
        queue.sync {
            stopWatching(sessionId)
            remove(fileURL(sessionId: sessionId))
        }
    }

    /// Stops watching every session and removes every file in the folder, including ones a
    /// crashed run left behind. Run before any session is live.
    public func sweep() {
        queue.sync {
            for id in Array(watches.keys) { stopWatching(id) }
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            do {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    remove(file)
                }
            } catch {
                log("could not list the status line folder \(directory.path) — \(error)")
            }
        }
    }

    // MARK: - Confined to `queue`

    private func stopWatching(_ sessionId: String) {
        watches.removeValue(forKey: sessionId)?.source.cancel()
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
            stopWatching(sessionId)
            log("the status line file \(watch.url.path) was removed or replaced — this session's usage is no longer heard")
            return
        }
        watch.epoch += 1
        watch.attempts = 0
        check(sessionId, watch)
    }

    private func check(_ sessionId: String, _ watch: Watch) {
        guard watches[sessionId] === watch else { return }
        switch read(watch.url, now()) {
        case .report(let body, let reading):
            watch.attempts = 0
            watch.lastFailure = nil
            if let reading { deliver(body, reading) }
        case .empty:
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
