import Foundation
import Observation

/// The sidebar's remembered layout: the order projects were first opened in, per-folder
/// expand/collapse choices, and which collapsible sections are open. Persisted as one JSON value
/// in an injectable UserDefaults suite (as `AppPreferences` is), so tests never touch the real domain.
@MainActor
@Observable
public final class SidebarState {
    public enum Section: String, Codable, CaseIterable, Sendable {
        case more, servers, cloud, usage, earlier
    }

    private struct Stored: Codable {
        var projectOrder: [String] = []
        var expandOverrides: [String: Bool] = [:]
        var openSections: Set<Section> = []
    }

    static let key = "sidebarState"

    public private(set) var projectOrder: [String]
    public private(set) var expandOverrides: [String: Bool]
    private var openSections: Set<Section>
    /// The project holding the open terminal at the last `noteSelectedProject`. In memory: moving
    /// into a project is what opens it, and that only has meaning within a run.
    @ObservationIgnored private var selectedProject: String?
    /// The projects that were coral at the last `noteCoral`. In memory: a project coral at launch
    /// counts as newly coral once.
    @ObservationIgnored private var coralProjects: Set<String> = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var stored = Stored()
        if let data = defaults.data(forKey: Self.key) {
            do {
                stored = try JSONDecoder().decode(Stored.self, from: data)
            } catch {
                NSLog("[linkC] sidebar state is unreadable, starting fresh — %@", String(describing: error))
            }
        }
        projectOrder = stored.projectOrder
        expandOverrides = stored.expandOverrides
        openSections = stored.openSections
    }

    /// Append any project not seen before; everyone else keeps their place.
    public func noteProjects(_ paths: [String]) {
        var order = projectOrder
        for path in paths where !order.contains(path) {
            order.append(path)
        }
        guard order != projectOrder else { return }
        projectOrder = order
        save()
    }

    /// Forget folders that no longer have a live session or an Earlier entry. Run once at launch.
    public func prune(keeping paths: Set<String>) {
        let order = projectOrder.filter { paths.contains($0) }
        let overrides = expandOverrides.filter { paths.contains($0.key) }
        guard order != projectOrder || overrides != expandOverrides else { return }
        projectOrder = order
        expandOverrides = overrides
        save()
    }

    public func setExpanded(_ path: String, _ expanded: Bool) {
        guard expandOverrides[path] != expanded else { return }
        expandOverrides[path] = expanded
        save()
    }

    /// A project that just turned coral expands, overriding a manual collapse. One that stays
    /// coral is left alone, so collapsing it by hand sticks until it next turns coral.
    public func noteCoral(_ paths: Set<String>) {
        let newlyCoral = paths.subtracting(coralProjects)
        coralProjects = paths
        var changed = false
        for path in newlyCoral where expandOverrides[path] != true {
            expandOverrides[path] = true
            changed = true
        }
        if changed { save() }
    }

    /// The project holding the open terminal. Moving into one drops its override, so it opens —
    /// and a collapse the user makes afterwards sticks until they leave and come back.
    public func noteSelectedProject(_ path: String?) {
        guard path != selectedProject else { return }
        selectedProject = path
        guard let path, expandOverrides[path] != nil else { return }
        expandOverrides[path] = nil
        save()
    }

    public func isOpen(_ section: Section) -> Bool {
        openSections.contains(section)
    }

    public func toggle(_ section: Section) {
        if openSections.contains(section) {
            openSections.remove(section)
        } else {
            openSections.insert(section)
        }
        save()
    }

    private func save() {
        let stored = Stored(projectOrder: projectOrder, expandOverrides: expandOverrides, openSections: openSections)
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
        } catch {
            NSLog("[linkC] sidebar state could not be saved — %@", String(describing: error))
        }
    }
}
