import Foundation
import Observation

/// A compose project the screen has seen — enough identity to bring it up from cold.
public struct KnownStack: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let workingDir: String
    /// Service names from the compose file, when known (folder-added stacks) — lets a
    /// never-run stack show what it contains. ps-discovered stacks may have none.
    public let services: [String]
    public var id: String { name }

    init(name: String, workingDir: String, services: [String] = []) {
        self.name = name
        self.workingDir = workingDir
        self.services = services
    }

    // Files written before `services` existed decode with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        workingDir = try container.decode(String.self, forKey: .workingDir)
        services = try container.decodeIfPresent([String].self, forKey: .services) ?? []
    }
}

/// Persists known compose projects so a fully-downed stack still shows (with Up) across
/// refreshes and app restarts. WorkspaceManifest's pattern: JSON file, every mutation
/// writes through, missing/corrupt files load as empty (a bad cache must never block).
@MainActor
@Observable
public final class KnownStacksStore {
    public private(set) var stacks: [KnownStack] = []

    private let fileURL: URL
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("known-stacks.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([KnownStack].self, from: data) {
            stacks = loaded
        }
    }

    /// Upsert by project name. `services: nil` (the ps-discovery path, which can't see the
    /// compose file) preserves whatever services an earlier folder-add recorded.
    public func remember(name: String, workingDir: String, services: [String]? = nil) {
        let index = stacks.firstIndex { $0.name == name }
        let stack = KnownStack(
            name: name,
            workingDir: workingDir,
            services: services ?? index.map { stacks[$0].services } ?? []
        )
        if let index {
            guard stacks[index] != stack else { return }
            stacks[index] = stack
        } else {
            stacks.append(stack)
        }
        persist()
    }

    public func forget(name: String) {
        stacks.removeAll { $0.name == name }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stacks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("linkC: failed to persist known stacks: \(error)")
        }
    }
}
