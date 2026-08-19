import XCTest
@testable import LinkCKit

/// Update detection is a plist comparison, nothing more: a readable dist bundle whose
/// CFBundleVersion differs from the running build is an update; anything else is quiet nil.
final class UpdateCheckTests: XCTestCase {

    private func makeDistBundle(build: String?) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-update-\(UUID().uuidString)/linkC.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let build {
            let plist: [String: Any] = ["CFBundleVersion": build, "CFBundleShortVersionString": "0.1.1"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return bundle
    }

    func testDifferentBuildIsAnUpdate() throws {
        let dist = try makeDistBundle(build: "def4567")
        defer { try? FileManager.default.removeItem(at: dist.deletingLastPathComponent()) }

        let info = UpdateCheck.available(ownBuild: "886a672", distBundle: dist)
        XCTAssertEqual(info, UpdateInfo(fromBuild: "886a672", toBuild: "def4567"))
    }

    func testSameBuildIsNot() throws {
        let dist = try makeDistBundle(build: "886a672")
        defer { try? FileManager.default.removeItem(at: dist.deletingLastPathComponent()) }
        XCTAssertNil(UpdateCheck.available(ownBuild: "886a672", distBundle: dist))
    }

    func testMissingOrUnreadableDistIsQuietlyNil() throws {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-update-nope/linkC.app")
        XCTAssertNil(UpdateCheck.available(ownBuild: "886a672", distBundle: gone))

        let noPlist = try makeDistBundle(build: nil)
        defer { try? FileManager.default.removeItem(at: noPlist.deletingLastPathComponent()) }
        XCTAssertNil(UpdateCheck.available(ownBuild: "886a672", distBundle: noPlist))
    }
}

/// The swap script is generated, not hand-run: it must wait for the app's PID to exit,
/// then copy, then relaunch — in that order, with paths shell-quoted.
final class UpdateSwapTests: XCTestCase {

    func testScriptStagesStampsSwapsRelaunchesAndSelfDeletes() throws {
        let script = UpdateSwap.script(
            pid: 12345,
            distPath: "/Users/x/my repo/dist.noindex/linkC.app",
            installPath: "/Applications/linkC.app"
        )
        // Order: wait → staged copy → re-stamp the dist pointer → re-sign → atomic swap →
        // relaunch → self-delete. The stamp is what keeps update detection alive across
        // updates (dist's plist never carries the key); the staging is what keeps a failed
        // copy from destroying the installed app.
        let wait = try XCTUnwrap(script.range(of: "kill -0 12345"))
        let stage = try XCTUnwrap(script.range(of: "if ditto"))
        let stamp = try XCTUnwrap(script.range(of: "Add :LinkCSourceDist"))
        let sign = try XCTUnwrap(script.range(of: "codesign"))
        let swap = try XCTUnwrap(script.range(of: "mv "))
        let launch = try XCTUnwrap(script.range(of: "open "))
        let cleanup = try XCTUnwrap(script.range(of: #"rm -- "$0""#))
        XCTAssertLessThan(wait.lowerBound, stage.lowerBound, "wait for exit before staging")
        XCTAssertLessThan(stage.lowerBound, stamp.lowerBound, "stage before stamping")
        XCTAssertLessThan(stamp.lowerBound, sign.lowerBound, "stamp before re-signing")
        XCTAssertLessThan(sign.lowerBound, swap.lowerBound, "sign before swapping")
        XCTAssertLessThan(swap.lowerBound, launch.lowerBound, "swap before relaunching")
        XCTAssertLessThan(launch.lowerBound, cleanup.lowerBound, "relaunch, then self-delete")
        XCTAssertTrue(script.contains("'/Users/x/my repo/dist.noindex/linkC.app'"),
                      "paths with spaces must be quoted")
        XCTAssertTrue(script.contains("'/Applications/linkC.app'"))
        // The destructive rm of the installed bundle lives inside the success branch only —
        // and `open` sits outside the branch, so a failed staging still relaunches the old app.
        let destroy = try XCTUnwrap(script.range(of: "rm -rf '/Applications/linkC.app'"))
        XCTAssertLessThan(stamp.lowerBound, destroy.lowerBound,
                          "the installed bundle is only removed after staging succeeded")
        XCTAssertLessThan(destroy.lowerBound, launch.lowerBound)
    }
}
