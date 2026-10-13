import Foundation

/// A fresh build waiting in the repo's dist folder, ready to swap in.
public struct UpdateInfo: Equatable, Sendable {
    public let fromBuild: String
    public let toBuild: String

    public init(fromBuild: String, toBuild: String) {
        self.fromBuild = fromBuild
        self.toBuild = toBuild
    }
}

/// Update detection for a device-only app: no network, no feed — just "does the bundle my
/// installer came from now hold a different build?" The installed copy learns that path
/// from the `LinkCSourceDist` Info.plist key `build-app.sh --install` stamps.
public enum UpdateCheck {
    /// A readable dist bundle whose CFBundleVersion differs from the running build is an
    /// update. A missing or unreadable dist is quietly nil — deleted build products are
    /// not an error.
    public static func available(ownBuild: String, distBundle: URL) -> UpdateInfo? {
        let plistURL = distBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let distBuild = dict["CFBundleVersion"] as? String,
              distBuild != ownBuild else { return nil }
        return UpdateInfo(fromBuild: ownBuild, toBuild: distBuild)
    }
}

/// The swap itself: a detached shell script that outlives the app. It stages the copy
/// beside the installed bundle, re-stamps `LinkCSourceDist` (dist's plist never carries
/// it — without this the FIRST in-app update would kill detection forever) and re-signs,
/// then atomically replaces the old bundle. The relaunch sits OUTSIDE the success branch:
/// a failed staging (deleted dist, disk full, a locked keychain) leaves the installed app
/// untouched and still brings it back. Nothing the app can watch runs while it is gone, so
/// the script writes what it did to `logPath`, and anything the user must hear about — a
/// failed swap, or grants about to be lost — to `noticePath`, which the next launch shows.
/// The script deletes itself last.
public enum UpdateSwap {
    /// This Mac's own code-signing identity, which `build-app.sh` signs with too. macOS ties
    /// privacy grants (Screen Recording, notifications) to the app's signature, and an ad-hoc
    /// one changes with every build — a stable identity keeps the grants across updates.
    /// Without it in the keychain, both sign ad-hoc.
    public static let signingIdentity = "linkC Local Signing"

    private static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
    }
    /// Where the swap writes what it did.
    public static var logURL: URL { logs.appendingPathComponent("linkC-update.log") }
    /// Where the swap leaves a message for the next launch.
    public static var noticeURL: URL { logs.appendingPathComponent("linkC-update-notice.txt") }

    public static func script(
        pid: Int32, distPath: String, installPath: String,
        logPath: String = UpdateSwap.logURL.path, noticePath: String = UpdateSwap.noticeURL.path
    ) -> String {
        let dist = shellQuoted(distPath)
        let install = shellQuoted(installPath)
        let stage = shellQuoted(installPath + ".update")
        let stagePlist = shellQuoted(installPath + ".update/Contents/Info.plist")
        // PlistBuddy takes the rest of the -c string as the value, spaces included; the
        // whole command is one shell-quoted argument.
        let stamp = shellQuoted("Add :LinkCSourceDist string \(distPath)")
        let identity = shellQuoted(signingIdentity)
        // `case` patterns: the wildcards stay outside the quotes, or they match only themselves.
        let listed = "*" + shellQuoted("\"\(signingIdentity)\"") + "*"
        let authority = "*" + shellQuoted("Authority=\(signingIdentity)") + "*"
        let log = shellQuoted(logPath)
        let notice = shellQuoted(noticePath)
        let downgraded = shellQuoted(
            "This update was signed ad-hoc: the \"\(signingIdentity)\" identity wasn't in the keychain, "
            + "so macOS will ask for linkC's permissions again. scripts/make-signing-identity.sh makes a new one.")
        let failed = shellQuoted(
            "The update couldn't be installed, so the previous build is still running. Details: \(logPath)")
        let unmoved = shellQuoted(
            "The update couldn't replace the installed app, which was already removed. The new build is at "
            + "\(installPath).update; move it into place by hand. Details: \(logPath)")
        return """
        #!/bin/sh
        command exec >>\(log) 2>&1 || exec >/dev/null 2>&1
        printf '== %s update from %s\\n' "$(date)" \(dist)
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(stage)
        identity=-
        if listing=$(security find-identity -p codesigning); then
          case "$listing" in \(listed)) identity=\(identity) ;; esac
        else
          echo "security find-identity failed, so this update is signed ad-hoc"
        fi
        if [ "$identity" = - ]; then
          case "$(codesign -dvv \(install) 2>&1)" in
            \(authority)) printf '%s\\n' \(downgraded) > \(notice) ;;
          esac
        fi
        echo "signing with: $identity"
        if ditto \(dist) \(stage) \\
           && /usr/libexec/PlistBuddy -c \(stamp) \(stagePlist) \\
           && xattr -cr \(stage) \\
           && codesign --force --deep --sign "$identity" \(stage); then
          if rm -rf \(install) && mv \(stage) \(install); then
            echo "installed"
          else
            printf '%s\\n' \(unmoved) > \(notice)
            echo "failed: the staged update couldn't replace the installed app"
          fi
        else
          rm -rf \(stage)
          printf '%s\\n' \(failed) > \(notice)
          echo "failed: the previous build stays"
        fi
        open \(install)
        rm -- "$0"
        """
    }

    /// The message the last swap left for this launch, if any — read once, then removed. An
    /// unreadable notice is itself reported rather than dropped.
    public static func takeNotice(at url: URL = UpdateSwap.noticeURL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var notice: String?
        do {
            let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            notice = text.isEmpty ? nil : text
        } catch {
            notice = "The last update left a notice linkC couldn't read (\(error.localizedDescription)) Details: \(logURL.path)"
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Left in place it would show on every launch; say why it couldn't go.
            let removal = "linkC couldn't remove \(url.path): \(error.localizedDescription)"
            notice = notice.map { "\($0) (\(removal))" } ?? removal
        }
        return notice
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
