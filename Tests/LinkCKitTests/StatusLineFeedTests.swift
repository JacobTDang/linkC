import XCTest
@testable import LinkCKit

final class StatusLineFeedTests: XCTestCase {
    private let report = #"{"session_id":"c1","rate_limits":{"five_hour":{"used_percentage":66,"resets_at":1789980000},"seven_day":{"used_percentage":92,"resets_at":1790017200}}}"#
    private let shorterReport = #"{"rate_limits":{"five_hour":{"used_percentage":7,"resets_at":1789980000}}}"#

    private var directory: URL!
    private var feed: StatusLineFeed!
    private var delivered: Recorder<(body: Data, reading: AgentUsage)>!
    private var logged: Recorder<String>!

    /// A lock-guarded list a `@Sendable` callback can append to and a test can wait on.
    private final class Recorder<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Element] = []

        func record(_ element: Element) {
            lock.lock()
            stored.append(element)
            lock.unlock()
        }

        var all: [Element] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Hands out scripted outcomes in order, then repeats the last one, and counts every read.
    private final class ScriptedReader: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [StatusLineFile.Outcome]
        private var reads = 0

        init(_ outcomes: [StatusLineFile.Outcome]) { self.outcomes = outcomes }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }

        func read(_ url: URL, _ receivedAt: Date) -> StatusLineFile.Outcome {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
    }

    /// Torn until told the write has finished, then a complete report.
    private final class GatedReader: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var reads = 0
        private let reading: AgentUsage

        init(reading: AgentUsage) { self.reading = reading }

        func finishTheWrite() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }

        func read(_ url: URL, _ receivedAt: Date) -> StatusLineFile.Outcome {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return finished ? .report(body: Data("{}".utf8), reading: reading) : .torn
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-status-feed-\(UUID().uuidString)", isDirectory: true)
        delivered = Recorder()
        logged = Recorder()
    }

    override func tearDown() {
        feed?.sweep()
        try? FileManager.default.removeItem(at: directory)
    }

    /// - Parameter onDeliver: runs on the feed's queue after each delivery is recorded. A test that
    ///   blocks in it holds the feed still while it changes files the feed would react to.
    private func makeFeed(
        read: @escaping @Sendable (URL, Date) -> StatusLineFile.Outcome = StatusLineFile.read(at:receivedAt:),
        retryDelay: TimeInterval = 0.02,
        maxRetries: Int = 5,
        onDeliver: @escaping @Sendable () -> Void = {}
    ) -> StatusLineFeed {
        let delivered = delivered!
        let logged = logged!
        feed = StatusLineFeed(
            directory: directory,
            deliver: { body, reading in
                delivered.record((body, reading))
                onDeliver()
            },
            log: { logged.record($0) },
            read: read, retryDelay: retryDelay, maxRetries: maxRetries)
        return feed
    }

    /// What the status-line command does: empty the file, then write one line into it.
    private func commandWrites(_ line: String, to file: URL) throws {
        try Data((line + "\n").utf8).write(to: file)
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func testAReportTheCommandWritesIsDelivered() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        try commandWrites(report, to: file)

        XCTAssertTrue(waitUntil { delivered.all.count == 1 }, "the report must reach the feed's owner")
        XCTAssertEqual(delivered.all.first?.body, Data(report.utf8))
        XCTAssertEqual(delivered.all.first?.reading.windows.map(\.usedPercent), [66, 92])
        XCTAssertTrue(logged.all.isEmpty, "\(logged.all)")
    }

    func testEachRefreshIsDeliveredEvenWhenTheNewReportIsShorter() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 })
        try commandWrites(shorterReport, to: file)

        XCTAssertTrue(waitUntil { delivered.all.count == 2 })
        XCTAssertEqual(delivered.all.last?.reading.windows.map(\.usedPercent), [7])
        XCTAssertTrue(logged.all.isEmpty, "\(logged.all)")
    }

    func testAReportWithNoWindowsDeliversNothingAndLogsNothing() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        try commandWrites(#"{"session_id":"c1"}"#, to: file)
        settle()

        XCTAssertTrue(delivered.all.isEmpty)
        XCTAssertTrue(logged.all.isEmpty, "\(logged.all)")
    }

    func testTwoSessionsHaveTheirOwnFiles() throws {
        let feed = makeFeed()
        let first = try feed.watch(sessionId: "s1")
        let second = try feed.watch(sessionId: "s2")
        XCTAssertNotEqual(first, second)

        try commandWrites(report, to: first)
        try commandWrites(shorterReport, to: second)

        XCTAssertTrue(waitUntil { delivered.all.count == 2 })
        XCTAssertEqual(Set(delivered.all.map(\.body)), [Data(report.utf8), Data(shorterReport.utf8)])
    }

    /// Nothing is polled: a watched file that nobody writes is never read.
    func testAnIdleFeedNeverReadsTheFile() throws {
        let reader = ScriptedReader([.empty])
        let feed = makeFeed(read: reader.read)
        _ = try feed.watch(sessionId: "s1")
        _ = try feed.watch(sessionId: "s2")

        settle(0.5)

        XCTAssertEqual(reader.count, 0)
    }

    /// A read that lands mid-write sees a torn line. It is read again; it is never delivered.
    func testATornReadIsReadAgainAndDeliveredOnceComplete() throws {
        let complete = AgentUsage(agent: .claude, windows: [UsageWindow(label: "5h", usedPercent: 66, tokens: nil, resetsAt: nil)],
                                  planType: nil, observedAt: nil, unavailableReason: nil)
        let reader = ScriptedReader([.torn, .torn, .report(body: Data(report.utf8), reading: complete)])
        let file = try makeFeed(read: reader.read).watch(sessionId: "s1")

        try commandWrites(report, to: file)

        XCTAssertTrue(waitUntil { delivered.all.count == 1 }, "the retry must pick the finished line up")
        XCTAssertGreaterThanOrEqual(reader.count, 3, "two torn reads, then the complete one")
        XCTAssertTrue(logged.all.isEmpty, "a torn read that resolves is not an error: \(logged.all)")
    }

    /// The event for a finished write reads the file itself; a retry queued before it must not read
    /// it a second time and deliver the same report twice.
    func testARetryQueuedBeforeAnEventDoesNotDeliverTheSameReportTwice() throws {
        let reading = AgentUsage(agent: .claude, windows: [UsageWindow(label: "5h", usedPercent: 66, tokens: nil, resetsAt: nil)],
                                 planType: nil, observedAt: nil, unavailableReason: nil)
        let reader = GatedReader(reading: reading)
        let file = try makeFeed(read: reader.read, retryDelay: 0.3).watch(sessionId: "s1")
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { reader.count >= 1 })
        settle(0.05)

        reader.finishTheWrite()
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count >= 1 })
        settle(0.8)

        XCTAssertEqual(delivered.all.count, 1, "the retry that was already queued must stand down")
    }

    /// One write can raise two events, each of which finds the whole file: the second read is the same
    /// report and must not be delivered again. A different report, even one seen before, is delivered.
    func testAReportIdenticalToTheLastDeliveredIsNotDeliveredAgain() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 })
        try commandWrites(report, to: file)
        settle()
        XCTAssertEqual(delivered.all.count, 1, "the same bytes again are the same report")

        try commandWrites(shorterReport, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 2 })
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 3 }, "only the last delivered report counts as a repeat")
    }

    func testATornReadThatNeverCompletesDeliversNothingAndIsLoggedOnce() throws {
        let reader = ScriptedReader([.torn])
        let file = try makeFeed(read: reader.read, maxRetries: 3).watch(sessionId: "s1")

        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { reader.count >= 4 })
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { reader.count >= 8 })
        settle()

        XCTAssertTrue(delivered.all.isEmpty)
        XCTAssertEqual(logged.all.count, 1, "the same failure is logged once, not once per refresh: \(logged.all)")
        XCTAssertTrue(logged.all.first?.contains(file.path) == true, "\(logged.all)")
    }

    /// The file was emptied and nothing was written back: the command opened it and failed.
    func testAnEmptiedFileThatStaysEmptyIsLogged() throws {
        let reader = ScriptedReader([.empty])
        let file = try makeFeed(read: reader.read, maxRetries: 2).watch(sessionId: "s1")

        try commandWrites(report, to: file)

        XCTAssertTrue(waitUntil { logged.all.count == 1 })
        XCTAssertTrue(delivered.all.isEmpty)
    }

    func testGarbageKeepsTheLastReportAndIsLoggedOncePerChange() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 })

        try commandWrites("not json", to: file)
        XCTAssertTrue(waitUntil { logged.all.count == 1 })
        try commandWrites("not json", to: file)
        settle()
        XCTAssertEqual(logged.all.count, 1, "the same garbage again is not a change: \(logged.all)")

        try commandWrites("still not json {", to: file)
        XCTAssertTrue(waitUntil { logged.all.count == 2 })
        XCTAssertEqual(delivered.all.count, 1, "garbage never replaces the last report")

        try commandWrites(shorterReport, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 2 })
        try commandWrites("still not json {", to: file)
        XCTAssertTrue(waitUntil { logged.all.count == 3 }, "after a good report the same failure is news again")
    }

    func testUnwatchingStopsDeliveryAndRemovesTheFile() throws {
        let feed = makeFeed()
        let file = try feed.watch(sessionId: "s1")
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 })

        feed.unwatch(sessionId: "s1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        settle()
        XCTAssertEqual(delivered.all.count, 1)
        XCTAssertTrue(logged.all.isEmpty, "removing a file on purpose is not an error: \(logged.all)")
    }

    /// Once the file is gone the command's `>` makes a new one at the same path, and nobody would
    /// be watching it: the feed makes it again, private to the user, and watches that one.
    func testAFileRemovedUnderTheWatchIsMadeAgainAndHeardAgain() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        try FileManager.default.removeItem(at: file)

        XCTAssertTrue(waitUntil { logged.all.count == 1 })
        XCTAssertTrue(logged.all.first?.contains("\(file.path) was removed or replaced") == true, "\(logged.all)")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "the new file is private too")

        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 }, "a report written to the new file must be heard")
        settle()
        XCTAssertEqual(logged.all.count, 1, "one removal is one line: \(logged.all)")
    }

    /// The command may make the file again before the feed has looked: what it wrote is a report
    /// like any other, and the file it made is not left open to other users. The feed is held inside
    /// its first delivery, so it cannot look until the new file has its report.
    func testAFileTheCommandMadeAgainBeforeTheFeedLookedIsHeardAndMadePrivate() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let file = try makeFeed(onDeliver: { entered.signal(); release.wait() }).watch(sessionId: "s1")
        try commandWrites(report, to: file)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)

        try FileManager.default.removeItem(at: file)
        try commandWrites(shorterReport, to: file)   // what `>` does: a new file, open to other users
        release.signal()
        release.signal()

        XCTAssertTrue(waitUntil { delivered.all.count == 2 }, "\(logged.all)")
        XCTAssertEqual(delivered.all.last?.body, Data(shorterReport.utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// A file moved away (or replaced by a rename) has the same effect as one removed, and what the
    /// moved file holds is not the session's report.
    func testAFileMovedAwayUnderTheWatchIsMadeAgainEmptyAndHeardAgain() throws {
        let file = try makeFeed().watch(sessionId: "s1")
        let moved = directory.appendingPathComponent("moved-away")
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 })

        try FileManager.default.moveItem(at: file, to: moved)

        XCTAssertTrue(waitUntil { logged.all.count == 1 })
        XCTAssertTrue(logged.all.first?.contains("\(file.path) was removed or replaced") == true, "\(logged.all)")
        XCTAssertEqual(try Data(contentsOf: file), Data(), "the new file starts empty")
        try commandWrites(shorterReport, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 2 })
        XCTAssertEqual(delivered.all.last?.body, Data(shorterReport.utf8))
    }

    /// The folder itself can go (a cleanup of Application Support): the feed makes it again with the
    /// file. It is held inside a delivery while the folder goes, so it looks only when it is gone.
    func testAFolderRemovedUnderTheWatchIsMadeAgainToo() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let file = try makeFeed(onDeliver: { entered.signal(); release.wait() }).watch(sessionId: "s1")
        try commandWrites(report, to: file)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)

        try FileManager.default.removeItem(at: directory)
        release.signal()
        release.signal()

        XCTAssertTrue(waitUntil { logged.all.count == 1 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try commandWrites(shorterReport, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 2 })
    }

    /// A file that cannot be made again is said, not swallowed. The feed is held inside a delivery
    /// while the folder is taken away, so it finds the folder gone when it looks.
    func testAFileThatCannotBeMadeAgainIsLoggedAndTheSessionIsNoLongerHeard() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let file = try makeFeed(onDeliver: { entered.signal(); release.wait() }).watch(sessionId: "s1")
        try commandWrites(report, to: file)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)

        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)   // a file where the folder must go
        release.signal()

        XCTAssertTrue(waitUntil { logged.all.count == 1 })
        XCTAssertTrue(logged.all.first?.contains("\(file.path) was removed or replaced and could not be watched again") == true, "\(logged.all)")
    }

    func testWatchingASessionAgainStartsItsFileEmpty() throws {
        let feed = makeFeed()
        let file = try feed.watch(sessionId: "s1")
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 })

        let again = try feed.watch(sessionId: "s1")

        XCTAssertEqual(again, file)
        XCTAssertEqual(try Data(contentsOf: again), Data(), "a relaunch must not replay the last run's report")
    }

    func testSweepRemovesEveryFileLeftBehindAndStopsWatching() throws {
        let feed = makeFeed()
        let file = try feed.watch(sessionId: "s1")
        let orphan = directory.appendingPathComponent("orphan.line")
        try Data("x\n".utf8).write(to: orphan)

        feed.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(logged.all.isEmpty, "\(logged.all)")
    }

    /// A second linkC (a dev build beside the installed one) shares the folder: its startup sweep
    /// must not take the first one's files, only ones nobody holds.
    func testASweepLeavesTheFilesOfAFeedThatIsStillRunning() throws {
        let running = makeFeed()
        let file = try running.watch(sessionId: "s1")
        let orphan = directory.appendingPathComponent("orphan.line")
        try Data("x\n".utf8).write(to: orphan)
        let second = StatusLineFeed(directory: directory, deliver: { _, _ in }, log: { [logged] in logged!.record($0) })

        second.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "a file nobody holds is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a file a running feed holds is not")
        try commandWrites(report, to: file)
        XCTAssertTrue(waitUntil { delivered.all.count == 1 }, "the running feed still hears its session")
        XCTAssertTrue(logged.all.isEmpty, "\(logged.all)")
    }

    func testSweepOfAFolderThatDoesNotExistYetIsFine() {
        makeFeed().sweep()

        XCTAssertTrue(logged.all.isEmpty, "\(logged.all)")
    }

    func testTheFileIsPrivateToTheUser() throws {
        let file = try makeFeed().watch(sessionId: "s1")

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAnUnwritableFolderThrows() {
        let blocker = directory!
        try? Data().write(to: blocker)   // a file where the folder must go
        XCTAssertThrowsError(try makeFeed().watch(sessionId: "s1"))
        try? FileManager.default.removeItem(at: blocker)
    }
}
