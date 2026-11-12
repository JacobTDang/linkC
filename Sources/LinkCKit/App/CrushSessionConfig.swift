import Foundation

/// Where Crush keeps the user's config and data. `crush dirs` prints the same folders.
public struct CrushDirectories: Sendable, Equatable {
    /// The folder holding the user's `crush.json` (`CRUSH_GLOBAL_CONFIG`; normally `~/.config/crush`).
    public let config: URL
    /// The folder holding Crush's machine-owned state (`CRUSH_GLOBAL_DATA`; normally `~/.local/share/crush`).
    public let data: URL

    public init(config: URL, data: URL) {
        self.config = config
        self.data = data
    }

    /// Crush's folders for `home` under `environment`: its own variables first, then the XDG ones,
    /// then the macOS defaults.
    public static func standard(home: URL, environment: [String: String]) -> CrushDirectories {
        func folder(own: String, xdg: String, fallback: String) -> URL {
            if let value = environment[own], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            if let value = environment[xdg], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent("crush", isDirectory: true)
            }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return CrushDirectories(
            config: folder(own: "CRUSH_GLOBAL_CONFIG", xdg: "XDG_CONFIG_HOME", fallback: ".config/crush"),
            data: folder(own: "CRUSH_GLOBAL_DATA", xdg: "XDG_DATA_HOME", fallback: ".local/share/crush"))
    }
}

/// The per-session folders that pin a Crush session to one free model. See
/// docs/superpowers/specs/2026-11-12-freebuff-kilo-crush-design.md §4.3.
///
/// Crush's TUI has no model flag. `CRUSH_GLOBAL_CONFIG` names a folder, and Crush reads `crush.json`
/// from it as the global config, so each session gets its own folder holding the user's `crush.json`
/// with `models.large` and `models.small` set to the free model. The user's providers and key stay.
///
/// Two more places can override the pin, both checked on Crush 0.101.0:
/// - `<data folder>/crush.json`, read after the global config, where Crush saves a model picked in
///   its TUI. The session gets its own data folder (`CRUSH_GLOBAL_DATA`), a copy of the user's with
///   `models` dropped from that file.
/// - a `crush.json` or `.crush.json` in the project that sets a model, and any `crushrc` or `.crushrc`
///   in the project or above it, or a `crushrc` beside the global `crush.json`. A crushrc is a shell
///   script whose effect linkC cannot read off its text, so one that applies is refused whatever it
///   says. A launch that finds one is refused, never run unpinned.
///
/// A session folder that exists when a session is prepared is deleted first; if it cannot be deleted
/// whole, the preparation fails, so a stale `data/crush.json` is never launched on.
///
/// The user's own files are only ever read.
public struct CrushSessionConfig: Sendable {
    public static let configKey = "CRUSH_GLOBAL_CONFIG"
    public static let dataKey = "CRUSH_GLOBAL_DATA"

    private static let configFileName = "crush.json"
    private static let projectFileNames = [".crushrc", "crushrc", ".crush.json", "crush.json"]

    public let user: CrushDirectories
    /// The folder the per-session folders live in: `<root>/<session id>/{config,data}`.
    public let root: URL

    public init(user: CrushDirectories, root: URL) {
        self.user = user
        self.root = root
    }

    /// Crush runs free models only (`CrushFreeModels`).
    public static func isFree(_ id: String) -> Bool {
        CrushFreeModels.isFree(id)
    }

    /// `openrouter/nvidia/x:free` as Crush's `{"provider": "openrouter", "model": "nvidia/x:free"}`.
    static func split(_ id: String) throws -> (provider: String, model: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CrushFreeModels.isFree(trimmed) else {
            throw LinkCError.process("\(id) is not a free Crush model")
        }
        return ("openrouter", String(trimmed.dropFirst(CrushFreeModels.provider.count)))
    }

    func folder(for sessionId: String) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// Writes the session's folders and returns the environment that points Crush at them. Throws, and
    /// leaves nothing behind, when the model is not free, a file cannot be read, a project config would
    /// override the pin, or a folder cannot be written.
    func prepare(sessionId: String, cwd: String, model: String) throws -> [String: String] {
        guard !sessionId.isEmpty, !sessionId.contains("/"), sessionId != ".", sessionId != ".." else {
            throw LinkCError.process("\"\(sessionId)\" is not a session id Crush's folders can be named for")
        }
        let pin = try Self.split(model)
        try refuseUserCrushrc()
        try refuseProjectModels(from: cwd)

        var config = try readObject(user.config.appendingPathComponent(Self.configFileName))
        var models = config["models"] as? [String: Any] ?? [:]
        let entry = ["provider": pin.provider, "model": pin.model]
        models["large"] = entry
        models["small"] = entry
        config["models"] = models
        let dataFiles = try readUserData()

        let session = folder(for: sessionId)
        let configFolder = session.appendingPathComponent("config", isDirectory: true)
        let dataFolder = session.appendingPathComponent("data", isDirectory: true)
        // A folder left from before may hold a `data/crush.json` that names a paid model, and only the
        // files below are rewritten over it. It goes first, and if it cannot, nothing launches on it.
        try Self.removeFolder(session)
        do {
            let fm = FileManager.default
            for dir in [configFolder, dataFolder] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try Self.write(try Self.serialize(config), to: configFolder.appendingPathComponent(Self.configFileName))
            for (name, data) in dataFiles {
                try Self.write(data, to: dataFolder.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: session)
            throw LinkCError.process("could not write the config that pins Crush's model in \(session.path) — \(error.localizedDescription)")
        }
        return [Self.configKey: configFolder.path, Self.dataKey: dataFolder.path]
    }

    /// Deletes one session's folders. Idempotent. Throws, naming the folder, when it cannot be deleted
    /// whole; `prepare` for that id then refuses to run until it is.
    func remove(sessionId: String) throws {
        guard !sessionId.isEmpty, !sessionId.contains("/"), sessionId != ".", sessionId != ".." else { return }
        try Self.removeFolder(folder(for: sessionId))
    }

    /// Deletes every session's folders: the leftovers of a linkC that quit or crashed. Throws, naming
    /// the folder, when they cannot be deleted whole.
    func sweep() throws {
        try Self.removeFolder(root)
    }

    /// Deletes `url` and checks that it is gone: a folder left half-deleted could keep a file that
    /// overrides the pin.
    private static func removeFolder(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw LinkCError.process("could not delete Crush's per-session folder \(url.path), which may hold a model that overrides the free one — \(error.localizedDescription)")
        }
        guard !fm.fileExists(atPath: url.path) else {
            throw LinkCError.process("could not delete Crush's per-session folder \(url.path), which may hold a model that overrides the free one")
        }
    }

    // MARK: - Reading the user's files

    /// The JSON object in `url`: `{}` when the file is missing or empty. A file that is not an object
    /// is refused by name, since copying around it would drop the user's providers.
    private func readObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LinkCError.process("could not read \(url.path) — \(error.localizedDescription)")
        }
        guard !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LinkCError.process("\(url.path) is not a JSON object linkC can read, so it will not launch Crush on it")
        }
        return object
    }

    /// The regular files in the user's data folder, by name. `crush.json` loses its `models`: the copy
    /// keeps a key saved through the TUI, not a model picked there.
    private func readUserData() throws -> [(name: String, data: Data)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: user.data.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: user.data, includingPropertiesForKeys: [.isRegularFileKey])
        } catch {
            throw LinkCError.process("could not read Crush's data folder \(user.data.path) — \(error.localizedDescription)")
        }
        var files: [(String, Data)] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent == Self.configFileName {
                var saved = try readObject(url)
                saved.removeValue(forKey: "models")
                files.append((url.lastPathComponent, try Self.serialize(saved)))
            } else {
                do {
                    files.append((url.lastPathComponent, try Data(contentsOf: url)))
                } catch {
                    throw LinkCError.process("could not read \(url.path) — \(error.localizedDescription)")
                }
            }
        }
        return files
    }

    // MARK: - Things that would override the pin

    /// A `crushrc` next to the global `crush.json` is applied over it, so a `model` line in it would
    /// undo the pin. linkC does not rewrite shell scripts: the launch is refused.
    private func refuseUserCrushrc() throws {
        let rc = user.config.appendingPathComponent("crushrc")
        guard FileManager.default.fileExists(atPath: rc.path) else { return }
        throw LinkCError.process("\(rc.path) exists, and Crush applies a crushrc over crush.json, so linkC cannot pin a free model past it — move its settings into crush.json to run Crush from linkC")
    }

    /// Crush merges project configs over the global one. A project's own `models` would run the session
    /// on a model linkC did not choose, and a `crushrc` is a script that could set one in ways its text
    /// does not show, so any crushrc is refused. Looks in the folder and every one above it.
    private func refuseProjectModels(from cwd: String) throws {
        var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        while true {
            for name in Self.projectFileNames {
                let file = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                if file.lastPathComponent.hasSuffix("rc") {
                    throw LinkCError.process("\(file.path) is a Crush crushrc script, which can set a model linkC cannot see, so it will not launch Crush with it — remove it to run Crush from linkC here")
                }
                if try setsModel(file) {
                    throw LinkCError.process("\(file.path) sets a Crush model, which would override the free model linkC pins for this session — remove it to run Crush from linkC here")
                }
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { return }
            dir = parent
        }
    }

    private func setsModel(_ file: URL) throws -> Bool {
        let object = try readObject(file)
        return !((object["models"] as? [String: Any])?.isEmpty ?? true)
    }

    // MARK: - Writing

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
