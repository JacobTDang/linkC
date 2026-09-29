import XCTest
import Darwin
@testable import LinkCKit

/// `InboxStore` reads `inbox.json` for every read-only question the relay asks — several times a
/// tick per workspace. The decoded copy is cached per file, keyed by the file's identity, so an
/// unchanged file is not opened, read and decoded again. These tests pin both halves of that:
/// the reads that disappear, and the cases where the cache must NOT be trusted.
final class InboxReadCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-inbox-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func diskLoads(_ store: InboxStore) -> Int {
        StateFileReadCounter.shared.count(path: store.inboxURL.path)
    }

    func testRepeatedReadsOfAnUnchangedInboxLoadItOnce() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "brief", files: [])
        let before = diskLoads(store)

        for _ in 0..<10 {
            _ = try store.openTasks()
            _ = try store.fetchPending()
            _ = try store.isAgentLimited(agent: .claude)
            _ = try store.leaseHolders(for: ["a.swift"])
            _ = try store.load()
        }

        XCTAssertEqual(diskLoads(store) - before, 1, "50 read-only calls over one unchanged file should decode it once")
    }

    func testEveryReadOnlyCallSharesTheOneCachedCopy() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let task = try store.createTask(from: .claude, to: .codex, prompt: "brief", files: ["a.swift"])
        _ = try store.enqueue(from: .codex, to: .claude, kind: .completion, taskId: task.id, body: "done")
        _ = try store.load()
        let before = diskLoads(store)

        XCTAssertEqual(try store.task(id: task.id)?.prompt, "brief")
        XCTAssertEqual(try store.task(matching: task.id)?.id, task.id)
        XCTAssertEqual(try store.openTasks(for: .codex).map(\.id), [task.id])
        XCTAssertEqual(try store.leaseHolders(for: ["a.swift"]).map(\.id), [task.id])
        XCTAssertEqual(try store.fetchPending().count, 1)
        XCTAssertNil(try store.isAgentLimited(agent: .claude))

        XCTAssertEqual(diskLoads(store) - before, 0)
    }

    /// The whole point of keying on identity: the next read after another writer's change must
    /// see it, not a stale copy.
    func testTheNextReadSeesAChangeAnotherProcessMade() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "first", files: [])
        XCTAssertEqual(try store.openTasks().count, 1, "warms the cache")

        var inbox = try store.load()
        inbox.tasks.append(TaskRecord(fromAgent: .claude, toAgent: .codex, prompt: "second"))
        try ForeignInboxWriter.replace(inbox, in: store)

        XCTAssertEqual(try store.openTasks().map(\.prompt), ["first", "second"])
        XCTAssertEqual(try store.load().tasks.count, 2)
    }

    /// An editor that rewrites the file in place keeps the inode: the modification time and size
    /// still have to give it away.
    func testTheNextReadSeesAnInPlaceRewrite() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "brief one", files: [])
        XCTAssertEqual(try store.openTasks().first?.prompt, "brief one", "warms the cache")

        let original = try String(contentsOf: store.inboxURL, encoding: .utf8)
        try original.replacingOccurrences(of: "brief one", with: "brief number two")
            .write(to: store.inboxURL, atomically: false, encoding: .utf8)

        XCTAssertEqual(try store.openTasks().first?.prompt, "brief number two")
    }

    /// Even when the cached copy is provably current, a write reads the file itself under the lock:
    /// the cache answers questions, it never seeds a write.
    func testAWriteReadsTheFileEvenWhenTheCachedCopyIsCurrent() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "brief", files: [])
        XCTAssertEqual(try store.openTasks().count, 1, "warms the cache")
        let before = diskLoads(store)

        _ = try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "note")

        XCTAssertEqual(diskLoads(store) - before, 1)
    }

    /// A read-modify-write must build on what is on disk under the lock. Serving it the cached copy
    /// would let it overwrite another process's write with a state that no longer exists.
    func testAWriteReadsFromDiskAndKeepsAnotherProcessesChange() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "mine", files: [])
        XCTAssertEqual(try store.openTasks().count, 1, "warms the cache")

        var inbox = try store.load()
        inbox.tasks.append(TaskRecord(fromAgent: .claude, toAgent: .agy, prompt: "theirs"))
        try ForeignInboxWriter.replace(inbox, in: store)
        let before = diskLoads(store)

        _ = try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "note")

        XCTAssertEqual(diskLoads(store) - before, 1, "a write always reads the file itself")
        let result = try store.load()
        XCTAssertEqual(Set(result.tasks.map(\.prompt)), ["mine", "theirs"], "the other process's task must survive our write")
        XCTAssertEqual(result.messages.count, 1)
    }

    func testAFileThatStopsDecodingStillThrowsWhenAGoodCopyIsCached() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "brief", files: [])
        XCTAssertEqual(try store.openTasks().count, 1, "warms the cache")

        let garbage = Data("{ not an inbox".utf8)
        try garbage.write(to: store.inboxURL)

        XCTAssertThrowsError(try store.openTasks(), "an unreadable file is an error, never an empty or stale inbox")
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.inboxURL), garbage, "the unreadable file is left untouched")
    }

    func testARemovedFileReadsAsEmptyNotAsTheCachedCopy() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "brief", files: [])
        XCTAssertEqual(try store.openTasks().count, 1, "warms the cache")

        try FileManager.default.removeItem(at: store.inboxURL)

        XCTAssertTrue(try store.openTasks().isEmpty)
        XCTAssertTrue(try store.load().messages.isEmpty)
    }

    /// The relay reads every workspace it knows about, most of which have no inbox at all. A read
    /// must not create a `.linkc` directory (or a lock file) in each of them.
    func testReadingAnAbsentInboxCreatesNothingOnDisk() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)

        XCTAssertTrue(try store.openTasks().isEmpty)
        XCTAssertTrue(try store.fetchPending().isEmpty)
        XCTAssertNil(try store.isAgentLimited(agent: .claude))
        XCTAssertEqual(try store.load().workspacePath, store.workspaceRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".linkc").path))
    }

    // MARK: - Bounded size

    /// Any identity will do: the cache keys entries by path and compares the identity it is given
    /// with the one it stored.
    private func someIdentity() throws -> FileIdentity {
        let file = tempDir.appendingPathComponent("identity.json")
        try Data("{}".utf8).write(to: file)
        guard case .present(let identity) = try FileIdentity.probe(file.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return identity
    }

    private func isCached(_ cache: InboxReadCache, _ path: String, _ identity: FileIdentity) -> Bool {
        cache.inbox(at: path, matching: identity) != nil
    }

    func testTheCacheHoldsAtMostItsCapacityAndDropsTheLeastRecentlyUsed() throws {
        let identity = try someIdentity()
        let cache = InboxReadCache(capacity: 3)

        for index in 0..<1000 {
            cache.store(Inbox(workspacePath: "w\(index)"), at: "/w\(index)/inbox.json", identity: identity)
        }

        let cached = (0..<1000).filter { isCached(cache, "/w\($0)/inbox.json", identity) }
        XCTAssertEqual(cached, [997, 998, 999], "only the three most recently stored inboxes remain")
    }

    func testAHitCountsAsUseSoTheColdestEntryIsTheOneDropped() throws {
        let identity = try someIdentity()
        let cache = InboxReadCache(capacity: 3)
        for name in ["a", "b", "c"] {
            cache.store(Inbox(workspacePath: name), at: name, identity: identity)
        }

        XCTAssertNotNil(cache.inbox(at: "a", matching: identity), "reading a makes b the coldest")
        cache.store(Inbox(workspacePath: "d"), at: "d", identity: identity)

        XCTAssertTrue(isCached(cache, "a", identity))
        XCTAssertFalse(isCached(cache, "b", identity))
        XCTAssertTrue(isCached(cache, "c", identity))
        XCTAssertTrue(isCached(cache, "d", identity))
    }

    func testRefreshingAPathKeepsEveryOtherEntry() throws {
        let identity = try someIdentity()
        let cache = InboxReadCache(capacity: 3)
        for name in ["a", "b", "c"] {
            cache.store(Inbox(workspacePath: name), at: name, identity: identity)
        }

        cache.store(Inbox(workspacePath: "a again"), at: "a", identity: identity)

        XCTAssertEqual(cache.inbox(at: "a", matching: identity)?.workspacePath, "a again")
        XCTAssertTrue(isCached(cache, "b", identity))
        XCTAssertTrue(isCached(cache, "c", identity))
    }

    /// The process-wide cache is the one the relay uses; it must be bounded too, not just a small
    /// cache built by a test.
    func testTheProcessWideCacheIsBoundedToItsCapacity() throws {
        let workspaces = InboxReadCache.defaultCapacity + 2
        var stores: [InboxStore] = []
        for index in 0..<workspaces {
            let root = tempDir.appendingPathComponent("workspace-\(index)").path
            let store = InboxStore(workspaceRoot: root)
            _ = try store.createTask(from: .claude, to: .codex, prompt: "brief \(index)", files: [])
            _ = try store.load()
            stores.append(store)
        }

        let newest = try XCTUnwrap(stores.last)
        let newestBefore = diskLoads(newest)
        _ = try newest.load()
        XCTAssertEqual(diskLoads(newest) - newestBefore, 0, "the newest inbox is still cached")

        let oldest = try XCTUnwrap(stores.first)
        let oldestBefore = diskLoads(oldest)
        _ = try oldest.load()
        XCTAssertEqual(diskLoads(oldest) - oldestBefore, 1, "the oldest was dropped to stay within the capacity")
    }

    /// Readers on several threads while one writer keeps replacing the file: every read is a
    /// consistent snapshot (a task list only ever grows here), and once the writer is done every
    /// reader converges on the final state. Run under ThreadSanitizer this also covers the cache's
    /// own locking.
    func testConcurrentReadersSeeOnlyWholeSnapshotsWhileAWriterReplacesTheFile() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.createTask(from: .claude, to: .codex, prompt: "task-0", files: [])
        let writes = 30
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "linkc.inbox-cache.test", attributes: .concurrent)
        let problems = Problems()
        let root = tempDir.path

        for reader in 0..<4 {
            group.enter()
            queue.async {
                defer { group.leave() }
                var seen = 0
                for _ in 0..<300 {
                    do {
                        let count = try InboxStore(workspaceRoot: root).openTasks().count
                        if count < seen { problems.add("reader \(reader) went back from \(seen) to \(count) tasks") }
                        seen = max(seen, count)
                    } catch {
                        problems.add("reader \(reader) threw \(error)")
                    }
                }
            }
        }
        group.enter()
        queue.async {
            defer { group.leave() }
            for index in 1...writes {
                do {
                    _ = try InboxStore(workspaceRoot: root)
                        .createTask(from: .claude, to: .codex, prompt: "task-\(index)", files: [])
                } catch {
                    problems.add("writer threw \(error)")
                }
            }
        }
        group.wait()

        XCTAssertEqual(problems.all, [])
        XCTAssertEqual(try store.openTasks().count, writes + 1)
    }

    private final class Problems: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func add(_ message: String) {
            lock.lock(); messages.append(message); lock.unlock()
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }; return messages
        }
    }
}
