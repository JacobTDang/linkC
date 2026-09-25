import Foundation
import Darwin

/// The app process groups linkC started and has not seen stop, saved so the next launch can stop
/// any that survived a crash or force quit. Each entry keeps the leader's start time, so a pid the
/// system reused for an unrelated process is never signalled.
public final class LinkCAppGroupLedger {
    struct Entry: Codable, Equatable {
        let pgid: pid_t
        let startSeconds: Int64
        let startMicros: Int32
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("app-groups.json", isDirectory: false)
    }

    /// The same Application Support folder linkC's other own files (models, shells) live in.
    public static var applicationSupport: LinkCAppGroupLedger {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LinkCAppGroupLedger(directory: dir)
    }

    /// Records a freshly spawned group leader, so a crash or force quit of linkC before it stops
    /// leaves a trail the next launch can clean up. Logs and does nothing when the start time
    /// can't be read — never crashes.
    public func record(_ pgid: pid_t) {
        guard let start = ProcessSnooper.startTime(of: pgid) else {
            NSLog("[linkC app] could not read the start time of app group %d — it will not be tracked for cleanup", pgid)
            return
        }
        lock.withLock {
            var entries = unlockedLoad()
            entries.removeAll { $0.pgid == pgid }
            entries.append(Entry(pgid: pgid, startSeconds: start.seconds, startMicros: start.micros))
            unlockedSave(entries)
        }
    }

    /// Forgets a group once it's confirmed gone (or handed off, e.g. to `stopAll`'s own escalation).
    public func forget(_ pgid: pid_t) {
        lock.withLock {
            var entries = unlockedLoad()
            let before = entries.count
            entries.removeAll { $0.pgid == pgid }
            guard entries.count != before else { return }
            unlockedSave(entries)
        }
    }

    /// Stops every leftover group from a previous run that crashed or was force-quit: SIGTERM at
    /// once to every entry whose pid is still alive with a matching start time, then SIGKILL to
    /// whatever is still alive after `grace`. An entry whose pid is gone, or whose start time no
    /// longer matches (the system reused the pid), is dropped with no signal at all. Blocks for
    /// at most `grace`, only when leftovers exist. Clears the file when done.
    public func stopLeftovers(grace: TimeInterval = 5) {
        let entries = lock.withLock { unlockedLoad() }
        guard !entries.isEmpty else { return }
        let toSignal = entries.compactMap { entry -> pid_t? in
            guard let current = ProcessSnooper.startTime(of: entry.pgid),
                  current.seconds == entry.startSeconds, current.micros == entry.startMicros
            else { return nil }
            return entry.pgid
        }
        if !toSignal.isEmpty {
            func groupIsGone(_ pgid: pid_t) -> Bool { kill(-pgid, 0) == -1 && errno == ESRCH }
            for pgid in toSignal { kill(-pgid, SIGTERM) }
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, !toSignal.allSatisfy(groupIsGone) { usleep(50_000) }
            for pgid in toSignal where !groupIsGone(pgid) { kill(-pgid, SIGKILL) }
            for pgid in toSignal {
                NSLog("[linkC app] stopped a leftover app group %d from a previous run", pgid)
            }
        }
        lock.withLock { unlockedSave([]) }
    }

    // MARK: - Test seams

    /// Test-only: the entries currently on disk.
    func load() -> [Entry] { lock.withLock { unlockedLoad() } }

    /// Test-only: records an entry with an arbitrary start time, bypassing the real kernel
    /// lookup — simulates a stale ledger entry whose pid the system has since reused.
    func recordForTesting(pgid: pid_t, startSeconds: Int64, startMicros: Int32) {
        lock.withLock {
            var entries = unlockedLoad()
            entries.removeAll { $0.pgid == pgid }
            entries.append(Entry(pgid: pgid, startSeconds: startSeconds, startMicros: startMicros))
            unlockedSave(entries)
        }
    }

    // MARK: - IO (must run inside `lock`)

    private func unlockedLoad() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func unlockedSave(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[linkC app] could not save the app group ledger at %@ — %@", fileURL.path, String(describing: error))
        }
    }
}
