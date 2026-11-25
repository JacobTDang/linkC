import Foundation

/// Copies each mod shipped in the app bundle's `Resources/mods` into
/// `~/Library/Application Support/linkC/mods/<name>`, keeping the installed copy current
/// without touching files the engine writes beside it (for example `.claude-plugin/types/`).
public struct BundledMods: Sendable {
    public let bundleModsDirectory: URL
    public let installDirectory: URL

    public init(bundleModsDirectory: URL, installDirectory: URL) {
        self.bundleModsDirectory = bundleModsDirectory
        self.installDirectory = installDirectory
    }

    /// Install or refresh every mod folder under `bundleModsDirectory`.
    public func install() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleModsDirectory.path) else { return }
        let names = try fm.contentsOfDirectory(atPath: bundleModsDirectory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            let source = bundleModsDirectory.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            try installMod(named: name, from: source)
        }
    }

    private func installMod(named name: String, from source: URL) throws {
        let fm = FileManager.default
        let dest = installDirectory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let shipped = try relativeFiles(under: source)
        for relative in shipped {
            let from = source.appendingPathComponent(relative)
            let to = dest.appendingPathComponent(relative)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) {
                try fm.removeItem(at: to)
            }
            try fm.copyItem(at: from, to: to)
        }
    }

    private func relativeFiles(under root: URL) throws -> [String] {
        let fm = FileManager.default
        // Keep `.claude-plugin/` (a hidden folder the mod ships); never skip it.
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        var files: [String] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            files.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return files.sorted()
    }
}
