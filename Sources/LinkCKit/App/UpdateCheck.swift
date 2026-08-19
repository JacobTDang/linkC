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
/// a failed staging (deleted dist, disk full) leaves the installed app untouched and
/// still brings it back. The script deletes itself last.
public enum UpdateSwap {
    public static func script(pid: Int32, distPath: String, installPath: String) -> String {
        let dist = shellQuoted(distPath)
        let install = shellQuoted(installPath)
        let stage = shellQuoted(installPath + ".update")
        let stagePlist = shellQuoted(installPath + ".update/Contents/Info.plist")
        // PlistBuddy takes the rest of the -c string as the value, spaces included; the
        // whole command is one shell-quoted argument.
        let stamp = shellQuoted("Add :LinkCSourceDist string \(distPath)")
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(stage)
        if ditto \(dist) \(stage) \\
           && /usr/libexec/PlistBuddy -c \(stamp) \(stagePlist) \\
           && codesign --force --deep --sign - \(stage); then
          rm -rf \(install)
          mv \(stage) \(install)
        else
          rm -rf \(stage)
        fi
        open \(install)
        rm -- "$0"
        """
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
