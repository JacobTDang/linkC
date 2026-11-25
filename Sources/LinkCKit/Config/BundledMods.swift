import Foundation

/// Copies each mod shipped in the app bundle's `Resources/mods` into
/// `~/Library/Application Support/linkC/mods/<name>`, keeping the installed copy current
/// without touching files the engine writes beside it (for example `.claude-plugin/types/`).
public struct BundledMods: Sendable {
    /// Bookkeeping of relative paths the last install wrote; never a shipped mod file.
    static let manifestName = ".linkc-shipped.json"

    public struct Failure: Error, LocalizedError, Equatable {
        public let modName: String
        public let detail: String

        public var errorDescription: String? {
            "Couldn't install the \(modName) mod: \(detail)"
        }
    }

    public let bundleModsDirectory: URL
    public let installDirectory: URL

    public init(bundleModsDirectory: URL, installDirectory: URL) {
        self.bundleModsDirectory = bundleModsDirectory
        self.installDirectory = installDirectory
    }

    /// Default install root: `~/Library/Application Support/linkC/mods`.
    public static var defaultInstallDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC/mods", isDirectory: true)
    }

    /// `Bundle.main`'s `Resources/mods`, or nil when this launch has no shipped mods folder.
    public static func bundleModsDirectory(in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let mods = resources.appendingPathComponent("mods", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mods.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return mods
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
        do {
            try installModBody(named: name, from: source)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(modName: name, detail: error.localizedDescription)
        }
    }

    private func installModBody(named name: String, from source: URL) throws {
        let fm = FileManager.default
        let dest = installDirectory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let shipped = try relativeFiles(under: source)
        let previous = try validatedManifest(loadManifest(at: dest), modRoot: dest)
        let previousSet = Set(previous)
        try sweepLeftoverStageTemps(in: dest)
        // Each file is swapped in whole (stage then replace/move). The set is not a
        // transaction — a later successful run heals a partial set.
        var staged: [(temp: URL, final: URL)] = []
        defer {
            for pair in staged {
                try? fm.removeItem(at: pair.temp)
            }
        }
        for relative in shipped {
            let fromURL = source.appendingPathComponent(relative)
            let to = dest.appendingPathComponent(relative)
            if fm.fileExists(atPath: to.path),
               let existing = try? Data(contentsOf: to),
               let incoming = try? Data(contentsOf: fromURL),
               existing == incoming {
                continue
            }
            // Stage under the mod root so a file→folder flip does not need the parent yet.
            let temp = dest.appendingPathComponent(".linkc-new-\(UUID().uuidString)")
            staged.append((temp, to)) // track before copy so a failed copy is still cleaned up
            try fm.copyItem(at: fromURL, to: temp)
        }
        while !staged.isEmpty {
            let pair = staged.removeFirst()
            do {
                try removeShippedFileBlockingDirectory(
                    for: pair.final, modRoot: dest, previousShipped: previousSet, modName: name
                )
                try fm.createDirectory(
                    at: pair.final.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: pair.final.path) {
                    _ = try fm.replaceItemAt(pair.final, withItemAt: pair.temp)
                } else {
                    try fm.moveItem(at: pair.temp, to: pair.final)
                }
            } catch {
                staged.insert(pair, at: 0) // still a temp for defer cleanup
                throw error
            }
        }

        let shippedSet = Set(shipped)
        for relative in previous where !shippedSet.contains(relative) {
            guard !isEngineTypesPath(relative), relative != Self.manifestName else {
                continue
            }
            // A former file may now be a directory prefix of a shipped path — leave it.
            if shipped.contains(where: { $0.hasPrefix(relative + "/") }) {
                continue
            }
            let url = dest.appendingPathComponent(relative)
            try assertNoSymlinkInPath(relative, under: dest, modName: name)
            guard isRegularFileLstat(at: url) else { continue }
            try fm.removeItem(at: url)
            try removeEmptyParentsCreatedByManifest(
                of: url, modRoot: dest, previousShipped: previousSet
            )
        }
        try saveManifest(shipped, at: dest)
    }

    /// Drop crash leftovers from a prior run: `.linkc-new-*` under the mod root and
    /// `*.linkc-new-*` beside any nested path (legacy staging location).
    private func sweepLeftoverStageTemps(in dest: URL) throws {
        let fm = FileManager.default
        let rootPath = dest.standardizedFileURL.path
        guard let enumerator = fm.enumerator(
            at: dest,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isRootTemp = name.hasPrefix(".linkc-new-")
            let isBesideTemp = name.contains(".linkc-new-")
            guard isRootTemp || isBesideTemp else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// When a shipped path becomes a folder (`foo` → `foo/bar.txt`), remove the old shipped
    /// file so `createDirectory` can proceed. Never delete an unshipped file in the way.
    private func removeShippedFileBlockingDirectory(
        for fileURL: URL,
        modRoot: URL,
        previousShipped: Set<String>,
        modName: String
    ) throws {
        let fm = FileManager.default
        let rootPath = modRoot.standardizedFileURL.path
        let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath.hasPrefix(rootPath + "/") || parentPath == rootPath else { return }
        let relativeParent = parentPath == rootPath
            ? ""
            : String(parentPath.dropFirst(rootPath.count + 1))
        guard !relativeParent.isEmpty else { return }

        var built = ""
        for component in relativeParent.split(separator: "/") {
            built = built.isEmpty ? String(component) : built + "/" + component
            let url = modRoot.appendingPathComponent(built)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard previousShipped.contains(built) else {
                throw Failure(
                    modName: modName,
                    detail: "an unshipped file is in the way at \(built)"
                )
            }
            try fm.removeItem(at: url)
        }
    }

    /// Reject empty, absolute, `.` / `..` components, escapes, and any path that passes through a
    /// symlink. A bad manifest must not authorize any delete.
    private func validatedManifest(_ entries: [String], modRoot: URL) throws -> [String] {
        let modName = modRoot.lastPathComponent
        let rootPath = modRoot.standardizedFileURL.path
        for entry in entries {
            if entry.isEmpty || entry.hasPrefix("/") {
                throw Failure(
                    modName: modName,
                    detail: "shipped-file manifest has an unsafe path \(entry.debugDescription)"
                )
            }
            let components = entry.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw Failure(
                    modName: modName,
                    detail: "shipped-file manifest has an unsafe path \(entry.debugDescription)"
                )
            }
            var built = ""
            for component in components {
                built = built.isEmpty ? component : built + "/" + component
                let step = modRoot.appendingPathComponent(built)
                if isSymlinkLstat(at: step) {
                    throw Failure(
                        modName: modName,
                        detail: "shipped-file manifest path passes through a symlink: \(entry.debugDescription)"
                    )
                }
            }
            let resolved = modRoot.appendingPathComponent(entry).standardizedFileURL.path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
                throw Failure(
                    modName: modName,
                    detail: "shipped-file manifest path escapes the mod folder: \(entry.debugDescription)"
                )
            }
        }
        return entries
    }

    /// `.claude-plugin/types` and anything under it, compared by path components case-insensitively.
    private func isEngineTypesPath(_ relative: String) -> Bool {
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count >= 2 else { return false }
        return comps[0].caseInsensitiveCompare(".claude-plugin") == .orderedSame
            && comps[1].caseInsensitiveCompare("types") == .orderedSame
    }

    private func isSymlinkLstat(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private func isRegularFileLstat(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private func assertNoSymlinkInPath(_ relative: String, under modRoot: URL, modName: String) throws {
        var built = ""
        for component in relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            built = built.isEmpty ? component : built + "/" + component
            if isSymlinkLstat(at: modRoot.appendingPathComponent(built)) {
                throw Failure(
                    modName: modName,
                    detail: "shipped-file manifest path passes through a symlink: \(relative.debugDescription)"
                )
            }
        }
    }

    /// After pruning a shipped file, drop now-empty parent dirs that the previous ship set created.
    private func removeEmptyParentsCreatedByManifest(
        of fileURL: URL,
        modRoot: URL,
        previousShipped: Set<String>
    ) throws {
        let fm = FileManager.default
        let rootPath = modRoot.standardizedFileURL.path
        var parent = fileURL.deletingLastPathComponent()
        while true {
            let parentPath = parent.standardizedFileURL.path
            guard parentPath.hasPrefix(rootPath + "/") else { break }
            let relative = String(parentPath.dropFirst(rootPath.count + 1))
            let createdByManifest = previousShipped.contains { entry in
                entry == relative || entry.hasPrefix(relative + "/")
            }
            guard createdByManifest else { break }
            let remaining = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? ["."]
            guard remaining.isEmpty else { break }
            try fm.removeItem(at: parent)
            parent = parent.deletingLastPathComponent()
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
            let relative = String(path.dropFirst(rootPath.count + 1))
            if relative == Self.manifestName { continue }
            if isEngineTypesPath(relative) { continue }
            files.append(relative)
        }
        return files.sorted()
    }

    private func loadManifest(at dest: URL) -> [String] {
        let url = dest.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    private func saveManifest(_ files: [String], at dest: URL) throws {
        let url = dest.appendingPathComponent(Self.manifestName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(files).write(to: url, options: .atomic)
    }
}
