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

/// The swap itself: a detached shell script that outlives the app. Order matters — wait
/// for the app's PID to actually exit (replacing a running bundle invites Gatekeeper and
/// half-copied-state weirdness), then copy, then relaunch.
public enum UpdateSwap {
    public static func script(pid: Int32, distPath: String, installPath: String) -> String {
        let dist = shellQuoted(distPath)
        let install = shellQuoted(installPath)
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        ditto \(dist) \(install)
        open \(install)
        """
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
