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
        var boardViewports: [String: BoardViewport]?
        var terminalProjects: [String: String]?
        var openApps: [String: [OpenApp]]?
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
    private var boardViewports: [String: BoardViewport] = [:]
    public private(set) var terminalProjects: [String: String] = [:]
    private var openAppsByProject: [String: [OpenApp]] = [:]
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
        boardViewports = stored.boardViewports ?? [:]
        terminalProjects = stored.terminalProjects ?? [:]
        openAppsByProject = stored.openApps ?? [:]
    }

    public func file(terminal id: String, under project: String) {
        let standardized = (project as NSString).standardizingPath
        guard terminalProjects[id] != standardized else { return }
        terminalProjects[id] = standardized
        save()
    }

    public func unfile(terminal id: String) {
        guard terminalProjects[id] != nil else { return }
        terminalProjects.removeValue(forKey: id)
        save()
    }

    public func pruneTerminals(keeping ids: Set<String>) {
        let kept = terminalProjects.filter { ids.contains($0.key) }
        guard kept != terminalProjects else { return }
        terminalProjects = kept
        save()
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

    /// The folders in use at start: `sessionPaths` (live sessions and Earlier entries) plus every
    /// filed project's folder, standardized — a filing is kept, and so is its order slot and its
    /// collapse state, until the terminal it names is truly dismissed, not merely un-live at start.
    public static func inUseProjects(sessionPaths: Set<String>, filed: [String: String]) -> Set<String> {
        sessionPaths.union(filed.values.map { ($0 as NSString).standardizingPath })
    }

    /// Forget folders that no longer have a live session or an Earlier entry. Run once at launch.
    public func prune(keeping paths: Set<String>) {
        let order = projectOrder.filter { paths.contains($0) }
        let overrides = expandOverrides.filter { paths.contains($0.key) }
        let viewports = boardViewports.filter { paths.contains($0.key) }
        guard order != projectOrder || overrides != expandOverrides || viewports != boardViewports else { return }
        projectOrder = order
        expandOverrides = overrides
        boardViewports = viewports
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

    /// The project holding the open terminal. Moving into one marks it open, so it opens and stays
    /// open after the agent on screen closes — and a collapse the user makes afterwards sticks
    /// until they leave and come back.
    public func noteSelectedProject(_ path: String?) {
        guard path != selectedProject else { return }
        selectedProject = path
        // Mark it open rather than clearing its override: cleared, the project would stay open
        // only while it held the selection, and closing the agent on screen would snap it shut.
        guard let path, expandOverrides[path] != true else { return }
        expandOverrides[path] = true
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
        let stored = Stored(projectOrder: projectOrder, expandOverrides: expandOverrides, openSections: openSections, boardViewports: boardViewports.isEmpty ? nil : boardViewports, terminalProjects: terminalProjects.isEmpty ? nil : terminalProjects, openApps: openAppsByProject.isEmpty ? nil : openAppsByProject)
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
        } catch {
            NSLog("[linkC] sidebar state could not be saved — %@", String(describing: error))
        }
    }

    /// Where this project's Board was last looked at. Personal, kept on this Mac only.
    public func boardViewport(for path: String) -> BoardViewport? {
        boardViewports[path]
    }

    public func setBoardViewport(_ viewport: BoardViewport, for path: String) {
        guard boardViewports[path] != viewport else { return }
        boardViewports[path] = viewport
        save()
    }

    /// The app tabs open in this project, in the order they were opened.
    public func openApps(in project: String) -> [OpenApp] {
        openAppsByProject[(project as NSString).standardizingPath] ?? []
    }

    public func openApp(_ app: OpenApp, in project: String) {
        let key = (project as NSString).standardizingPath
        var apps = openAppsByProject[key] ?? []
        guard !apps.contains(where: { $0.folder == app.folder }) else { return }
        apps.append(app)
        openAppsByProject[key] = apps
        save()
    }

    public func closeApp(folder: String, in project: String) {
        let key = (project as NSString).standardizingPath
        let target = (folder as NSString).standardizingPath
        guard var apps = openAppsByProject[key], apps.contains(where: { $0.folder == target }) else { return }
        apps.removeAll { $0.folder == target }
        openAppsByProject[key] = apps.isEmpty ? nil : apps
        save()
    }
}
