import Foundation
import Observation

/// A compose project the screen has seen — enough identity to bring it up from cold.
public struct KnownStack: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let workingDir: String
    public var id: String { name }
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

    public func remember(name: String, workingDir: String) {
        let stack = KnownStack(name: name, workingDir: workingDir)
        if let index = stacks.firstIndex(where: { $0.name == name }) {
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
