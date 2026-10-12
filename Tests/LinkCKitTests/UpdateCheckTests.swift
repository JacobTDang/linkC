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
        let choose = try XCTUnwrap(script.range(of: "if listing=$(security find-identity -p codesigning); then"))
        let sign = try XCTUnwrap(script.range(of: #"codesign --force --deep --sign "$identity" "#))
        XCTAssertLessThan(choose.lowerBound, sign.lowerBound, "the identity is chosen before re-signing")
        XCTAssertFalse(script.contains("--sign - "), "never a hard-coded ad-hoc signature")
    }

    /// The identity choice, run for real against a stub `security`: the identity when it is
    /// listed, ad-hoc when it isn't, and ad-hoc with a logged reason when `security` fails.
    func testIdentityChoiceRunsForReal() throws {
        let script = UpdateSwap.script(pid: 1, distPath: "/d/linkC.app", installPath: "/Applications/linkC.app")
        let block = try Self.block(of: script, from: "identity=-")
        let sandbox = try Sandbox()
        XCTAssertEqual(try sandbox.run(block + "\nprintf '[%s]' \"$identity\"",
                                       stubs: ["security": "echo '  1) B845 \"linkC Local Signing\" (CSSMERR_TP_NOT_TRUSTED)'"]),
                       "[linkC Local Signing]")
        XCTAssertEqual(try sandbox.run(block + "\nprintf '[%s]' \"$identity\"",
                                       stubs: ["security": "echo '     0 valid identities found'"]),
                       "[-]")
        let failed = try sandbox.run(block + "\nprintf '[%s]' \"$identity\"", stubs: ["security": "exit 44"])
        XCTAssertTrue(failed.hasSuffix("[-]"), failed)
        XCTAssertTrue(failed.contains("security find-identity failed"), "a failing keychain lookup is logged: \(failed)")
    }

    /// Falling back to ad-hoc over an app that carried the local identity would quietly cost the
    /// user every privacy grant: the swap leaves a notice saying so.
    func testAnAdHocSwapOverALocallySignedAppLeavesANotice() throws {
        let sandbox = try Sandbox()
        let notice = sandbox.dir.appendingPathComponent("notice.txt")
        let script = UpdateSwap.script(pid: 1, distPath: "/d/linkC.app", installPath: "/Applications/linkC.app",
                                       logPath: "/dev/null", noticePath: notice.path)
        let block = try Self.block(of: script, from: #"if [ "$identity" = - ]; then"#)
        // Like the real tool, Authority lines appear only at -dvv.
        let authorityAtDvv = #"case "$1" in -dvv) echo 'Authority=linkC Local Signing' >&2 ;; *) echo 'Signature size=9000' >&2 ;; esac"#
        _ = try sandbox.run("identity=-\n" + block, stubs: ["codesign": authorityAtDvv])
        let text = try String(contentsOf: notice, encoding: .utf8)
        XCTAssertTrue(text.contains("signed ad-hoc"), text)
        try FileManager.default.removeItem(at: notice)
        _ = try sandbox.run("identity=-\n" + block, stubs: ["codesign": "echo 'Signature=adhoc' >&2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: notice.path), "an app that was ad-hoc already loses nothing")
    }

    /// A swap that can't stage or sign keeps the old app, logs why, and leaves a notice the next
    /// launch shows — run for real, with a dist that isn't there.
    func testAFailedSwapLogsAndLeavesANotice() throws {
        let sandbox = try Sandbox()
        let log = sandbox.dir.appendingPathComponent("update.log")
        let notice = sandbox.dir.appendingPathComponent("notice.txt")
        let script = UpdateSwap.script(
            pid: 999_999, distPath: sandbox.dir.appendingPathComponent("missing.app").path,
            installPath: sandbox.dir.appendingPathComponent("installed.app").path,
            logPath: log.path, noticePath: notice.path)
        let file = sandbox.dir.appendingPathComponent("swap.sh")
        try script.replacingOccurrences(of: "\nopen ", with: "\n: ").write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue(try String(contentsOf: notice, encoding: .utf8).contains("couldn't be installed"))
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).isEmpty, "the swap logs what it did")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the script still deletes itself")
    }

    /// The dist path reaches the log quoted like every other path: one with `$(...)` or a quote
    /// in it neither runs a command nor breaks the script.
    func testTheLogHeaderQuotesTheDistPath() throws {
        let script = UpdateSwap.script(pid: 1, distPath: #"/d/a"b$(touch pwned).app"#, installPath: "/Applications/linkC.app")
        let header = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("echo \"== ") })
        let sandbox = try Sandbox()
        let out = try sandbox.run(String(header), stubs: [:])
        XCTAssertTrue(out.contains(#"/d/a"b$(touch pwned).app"#), out)
    }

    /// The next launch takes the notice once: read, then gone.
    func testTakingTheNoticeReadsItOnce() throws {
        let sandbox = try Sandbox()
        let notice = sandbox.dir.appendingPathComponent("notice.txt")
        XCTAssertNil(UpdateSwap.takeNotice(at: notice))
        try "The update couldn't be installed.\n".write(to: notice, atomically: true, encoding: .utf8)
        XCTAssertEqual(UpdateSwap.takeNotice(at: notice), "The update couldn't be installed.")
        XCTAssertNil(UpdateSwap.takeNotice(at: notice))
    }

    /// A notice that can't be read is still reported, pointing at the log, and not left to repeat.
    func testAnUnreadableNoticeIsReportedAndRemoved() throws {
        let sandbox = try Sandbox()
        let notice = sandbox.dir.appendingPathComponent("notice.txt")
        try FileManager.default.createDirectory(at: notice, withIntermediateDirectories: true)   // unreadable as text
        let text = try XCTUnwrap(UpdateSwap.takeNotice(at: notice))
        XCTAssertTrue(text.contains(UpdateSwap.logURL.path), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notice.path))
    }

    /// build-app.sh and the swap must choose the same identity.
    func testBuildScriptSignsWithTheSameIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = try String(contentsOf: root.appendingPathComponent("build-app.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains(#"SIGN_IDENTITY="\#(UpdateSwap.signingIdentity)""#))
        let make = try String(contentsOf: root.appendingPathComponent("scripts/make-signing-identity.sh"), encoding: .utf8)
        XCTAssertTrue(make.contains(#"NAME="\#(UpdateSwap.signingIdentity)""#), "the script makes the identity both sign with")
    }

    /// The lines of `script` from the one starting with `first` through the first line that is
    /// exactly `fi` after it.
    private static func block(of script: String, from first: String) throws -> String {
        let lines = script.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix(first) }, "no line starting \(first)")
        let end = try XCTUnwrap(lines[start...].firstIndex(of: "fi"))
        return lines[start...end].joined(separator: "\n")
    }

    /// A temp dir whose stub tools come first on PATH, removed when the test lets go of it.
    private final class Sandbox {
        let dir: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-swap-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: dir) }

        func run(_ shell: String, stubs: [String: String]) throws -> String {
            for (name, body) in stubs {
                let stub = dir.appendingPathComponent(name)
                try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", shell]
            process.environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
