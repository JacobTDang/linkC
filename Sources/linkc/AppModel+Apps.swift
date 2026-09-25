import Foundation
import LinkCKit

/// App tabs: opening, starting and closing the local web apps a project can host. Nothing here
/// starts a process on its own — only `openApp`, `startApp` (Start/Retry) and the launch path
/// that calls them ever does.
extension AppModel {
    /// One open app tab: the tab id, the project it belongs to, and the app's folder and name.
    struct AppTabRef: Equatable {
        let id: String
        let project: String
        let folder: String
        let name: String
    }

    /// The apps this project can open: its own `.linkc/app.json`, then the ones registered in
    /// Settings. Read fresh (on the catalog's short TTL) every call.
    func apps(in project: String) -> [LinkCAppEntry] {
        appCatalog.apps(inProject: project, settings: preferences.linkCApps)
    }

    /// Opens (or re-selects) an app tab and starts it. Called from the strip's and the sidebar's
    /// + menus — the only places besides Start/Retry that ever start an app.
    func openApp(_ entry: LinkCAppEntry, in project: String) {
        let manifest: LinkCAppManifest
        switch entry.manifest {
        case .failure(let error):
            surface(error: error.localizedDescription)
            return
        case .success(let value):
            manifest = value
        }
        sidebarState.openApp(OpenApp(folder: entry.folder, name: entry.name), in: project)
        let id = ProjectTabs.appTabID(project: project, folder: entry.folder)
        if let process = appProcesses[id] {
            switch process.state {
            case .starting, .running: break
            case .asleep, .failed, .exited: process.manifest = manifest
            }
        } else {
            appProcesses[id] = LinkCAppProcess(folder: entry.folder, manifest: manifest)
        }
        let ref = AppTabRef(id: id, project: ProjectTabs.standardized(project), folder: entry.folder, name: entry.name)
        showApp(ref)
        startApp(ref)
    }

    /// Starts (or restarts) an app tab's process. The only path that runs the app's command —
    /// reached from `openApp` and from the pane's Start/Retry buttons, never automatically.
    func startApp(_ ref: AppTabRef) {
        guard let entry = apps(in: ref.project).first(where: { $0.folder == ref.folder }) else {
            surface(error: "\(ref.name): no app is configured at \(ref.folder) any more.")
            return
        }
        switch entry.manifest {
        case .failure(let error):
            surface(error: error.localizedDescription)
        case .success(let manifest):
            if let process = appProcesses[ref.id] {
                process.manifest = manifest
                process.start()
            } else {
                let process = LinkCAppProcess(folder: ref.folder, manifest: manifest)
                appProcesses[ref.id] = process
                process.start()
            }
        }
    }

    /// Stops the tab's process (fire-and-forget — quitting is the only path that waits) and
    /// forgets it, then removes the tab from the strip.
    func closeApp(_ tab: ProjectTab) {
        guard let project = currentProject,
              let open = sidebarState.openApps(in: project)
                  .first(where: { ProjectTabs.appTabID(project: project, folder: $0.folder) == tab.id })
        else { return }
        appProcesses[tab.id]?.stop()
        appProcesses[tab.id] = nil
        appWebViews[tab.id] = nil
        sidebarState.closeApp(folder: open.folder, in: project)
        clearAppTab(matching: tab.id)
    }
}
