import Foundation

/// Finds the compose file in a user-picked project folder, using compose's own documented
/// lookup order — so linkC accepts exactly the folders `docker compose` would.
public enum ComposeFile {
    public static let candidates = [
        "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml",
    ]

    /// The first candidate that exists as a regular file, or nil when the folder has none.
    public static func locate(in directory: String) -> String? {
        for name in candidates {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return path
            }
        }
        return nil
    }
}

/// The slice of `docker compose config --format json` linkC needs: the canonical project
/// name (compose's own, honoring a top-level `name:` — never guessed from the folder, so a
/// later `docker ps` discovery upserts the same entry) and the service names.
public struct ComposeConfig: Equatable, Sendable {
    public let name: String
    public let services: [String]

    public static func parse(_ data: Data) throws -> ComposeConfig {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.process("compose config output wasn't JSON: \(error.localizedDescription)")
        }
        guard let dict = object as? [String: Any],
              let name = dict["name"] as? String, !name.isEmpty else {
            throw LinkCError.process("compose config output has no project name")
        }
        let services = (dict["services"] as? [String: Any]).map { $0.keys.sorted() } ?? []
        return ComposeConfig(name: name, services: services)
    }
}
