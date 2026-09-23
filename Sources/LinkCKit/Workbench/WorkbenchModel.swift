import Foundation

/// What the board shows and edits: the loaded map, where its tiles sit, what linkC found when it
/// last looked, and the pending write. The band holds no logic of its own.
@MainActor
@Observable
public final class WorkbenchModel {
    public enum State: Equatable, Sendable {
        /// The project has no map yet.
        case empty
        case loaded
        /// The map could not be read, or an edit could not be written. Nothing is written while
        /// this holds: a file linkC could not read must never be overwritten.
        case failed(String)
    }

    public private(set) var state: State = .empty
    public private(set) var map: SystemMap = .empty
    public private(set) var statuses: [String: ComponentStatus] = [:]
    public private(set) var suggestions: [MapSuggestion] = []
    public private(set) var positions: [String: GridPoint] = [:]
    /// The last edit linkC would not make — a name already in use. Transient, and cleared by the
    /// next edit that lands: a mistyped name must not lock the board the way a broken file does.
    public private(set) var refusal: String?

    @ObservationIgnored private let store: SystemMapStore
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var generation = 0

    public init(
        store: SystemMapStore,
        settle: Duration = .milliseconds(600),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.store = store
        self.settle = settle
        self.sleep = sleep
    }

    /// Reads the project's map. A project with none is `empty`, not an error.
    public func load() {
        do {
            if let loaded = try store.load() {
                map = loaded
                state = .loaded
            } else {
                map = .empty
                state = .empty
            }
        } catch {
            map = .empty
            state = .failed(message(for: error))
        }
        relayout()
    }

    /// Starts a map for a project that has none. The first edit writes the file.
    public func startMap() {
        guard state == .empty else { return }
        map = .empty
        state = .loaded
    }

    public func reconcile(with discovered: [DiscoveredThing]) {
        let result = SystemReconciler.reconcile(map: map, discovered: discovered)
        statuses = result.statuses
        suggestions = result.suggestions
    }

    public func add(_ component: SystemComponent) {
        guard canEdit else { return }
        refusal = nil
        guard !map.components.contains(where: { $0.name.lowercased() == component.name.lowercased() }) else {
            refusal = "this project's map already names \"\(component.name)\""
            return
        }
        map.components.append(component)
        edited()
    }

    public func update(_ name: String, to component: SystemComponent) {
        guard canEdit, let index = indexOf(name) else { return }
        refusal = nil
        let clash = map.components.enumerated().contains { other in
            other.offset != index && other.element.name.lowercased() == component.name.lowercased()
        }
        guard !clash else {
            refusal = "this project's map already names \"\(component.name)\""
            return
        }
        map.components[index] = component
        edited()
    }

    public func remove(_ name: String) {
        guard canEdit, let index = indexOf(name) else { return }
        map.components.remove(at: index)
        edited()
    }

    public func move(_ name: String, to point: GridPoint) {
        guard canEdit, let index = indexOf(name) else { return }
        map.components[index].at = point
        edited()
    }

    /// Writes now rather than after the settle — for a sheet closing, and for tests.
    public func saveNow() {
        generation += 1
        write()
    }

    // MARK: - Internals

    private var canEdit: Bool {
        if case .failed = state { return false }
        return true
    }

    private func indexOf(_ name: String) -> Int? {
        map.components.firstIndex { $0.name.lowercased() == name.lowercased() }
    }

    private func edited() {
        relayout()
        scheduleWrite()
    }

    private func relayout() {
        positions = WorkbenchLayout.positions(for: map.components)
    }

    /// One write per burst of edits: a drag is one file change, not fifty.
    private func scheduleWrite() {
        generation += 1
        let scheduled = generation
        let sleep = self.sleep
        let settle = self.settle
        Task { @MainActor [weak self] in
            await sleep(settle)
            guard let self, self.generation == scheduled else { return }
            self.write()
        }
    }

    private func write() {
        guard canEdit else { return }
        do {
            try store.save(map)
        } catch {
            state = .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? LinkCError { return error.localizedDescription }
        return String(describing: error)
    }
}
