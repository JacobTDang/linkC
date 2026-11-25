import XCTest
@testable import LinkCKit

@MainActor
final class SharedBrowserTests: XCTestCase {
    private final class Process: SharedBrowserProcess {
        var stopped = false
        func stop() { stopped = true }
    }

    private final class Launcher: SharedBrowserLaunching {
        let process = Process()
        var launches: [(String, [String])] = []
        var port = "43117\nignored\n"
        var available = true

        func isExecutable(_ path: String) -> Bool { available }

        func launch(executable: String, arguments: [String], profileDirectory: URL) throws -> any SharedBrowserProcess {
            launches.append((executable, arguments))
            try Data(port.utf8).write(to: profileDirectory.appendingPathComponent("DevToolsActivePort"))
            return process
        }
    }

    private final class TabCloser: SharedBrowserTabClosing {
        var closed: [(Int, String)] = []
        func closePinnedTab(port: Int, sessionName: String) throws { closed.append((port, sessionName)) }
    }

    func testStartsOnFirstSessionReadsChromePortAndStopsOnLast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launcher = Launcher()
        let closer = TabCloser()
        let browser = SharedBrowser(
            applicationSupport: root, chromePath: "/Applications/Google Chrome", launcher: launcher,
            tabCloser: closer, now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in })

        let first = browser.environment(projectPath: "/tmp/project/../project", sessionId: "S1")
        let second = browser.environment(projectPath: "/tmp/project", sessionId: "S2")

        XCTAssertEqual(first, ["AGENT_BROWSER_CDP": "43117", "AGENT_BROWSER_PIN_TAB": "1",
                               "AGENT_BROWSER_SESSION": "linkc-S1"])
        XCTAssertEqual(second?["AGENT_BROWSER_SESSION"], "linkc-S2")
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].1.contains("--remote-debugging-port=0"))
        XCTAssertTrue(launcher.launches[0].1.contains { $0.hasPrefix("--user-data-dir=") })

        browser.release(sessionId: "S1")
        XCTAssertEqual(closer.closed.map(\.1), ["linkc-S1"])
        XCTAssertFalse(launcher.process.stopped)
        browser.release(sessionId: "S2")
        XCTAssertEqual(closer.closed.map(\.1), ["linkc-S1", "linkc-S2"])
        XCTAssertTrue(launcher.process.stopped)
    }

    func testMissingChromeReportsOnceAndReturnsNoVariables() {
        var notices: [String] = []
        let launcher = Launcher()
        launcher.available = false
        let browser = SharedBrowser(
            applicationSupport: FileManager.default.temporaryDirectory,
            chromePath: "/missing/Google Chrome", launcher: launcher, report: { notices.append($0) })

        XCTAssertNil(browser.environment(projectPath: "/tmp/project", sessionId: "S1"))
        XCTAssertNil(browser.environment(projectPath: "/tmp/project", sessionId: "S2"))
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("Google Chrome"), notices[0])
    }
}
