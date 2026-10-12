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
        // iCloud-synced folders stamp Finder xattrs that codesign rejects as detritus —
        // the staged bundle must be cleaned before re-signing, same as build-app.sh does.
        let clean = try XCTUnwrap(script.range(of: "xattr -cr"))
        let sign = try XCTUnwrap(script.range(of: "codesign --force"))
        XCTAssertLessThan(stamp.lowerBound, clean.lowerBound)
        XCTAssertLessThan(clean.lowerBound, sign.lowerBound, "clean xattrs before re-signing")
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

    /// An ad-hoc signature changes with every build, and macOS ties privacy grants (Screen
    /// Recording, notifications) to the signature — so the swap re-signs with this Mac's stable
    /// local identity when the keychain has it, exactly as build-app.sh does, and ad-hoc otherwise.
    func testScriptReSignsWithTheLocalIdentityWhenTheKeychainHasIt() throws {
        let script = UpdateSwap.script(pid: 1, distPath: "/d/linkC.app", installPath: "/Applications/linkC.app")
        XCTAssertEqual(UpdateSwap.signingIdentity, "linkC Local Signing")
        let choose = try XCTUnwrap(script.range(of: #"security find-identity -p codesigning | grep -qF '"linkC Local Signing"'"#))
        let sign = try XCTUnwrap(script.range(of: #"codesign --force --deep --sign "$identity" "#))
        XCTAssertLessThan(choose.lowerBound, sign.lowerBound, "the identity is chosen before re-signing")
        XCTAssertTrue(script.contains("identity=-\n"), "ad-hoc when the keychain has no local identity")
        XCTAssertTrue(script.contains("identity='linkC Local Signing'"))
        XCTAssertFalse(script.contains("--sign - "), "never a hard-coded ad-hoc signature")
    }

    /// The identity choice, run for real: with no matching identity it falls back to ad-hoc.
    func testIdentityChoiceRunsAndPicksAdHocWithoutTheIdentity() throws {
        let script = UpdateSwap.script(pid: 1, distPath: "/d/linkC.app", installPath: "/Applications/linkC.app")
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.contains("find-identity") })
        // A stub `security` that lists no identities stands in for the keychain.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("security")
        try "#!/bin/sh\necho '     0 valid identities found'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let run = { (listing: String) throws -> String in
            try "#!/bin/sh\necho '\(listing)'\n".write(to: stub, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "identity=-\n\(line)\nprintf %s \"$identity\""]
            process.environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run("     0 valid identities found"), "-")
        XCTAssertEqual(try run(#"  1) B845 "linkC Local Signing" (CSSMERR_TP_NOT_TRUSTED)"#), "linkC Local Signing")
    }
}
