import LinkCKit
import SwiftUI

extension AppModel {
    /// The agent cards beside session `id`'s terminal, or nil when its agent's column is off. Built from
    /// the list the coordinator publishes and the repos git already named: it reads, never asks.
    func agentsColumn(for id: String) -> AgentsColumn? {
        guard let coordinator, let session = sessions.first(where: { $0.id == id }),
              preferences.showsAgentsColumn(for: session.agentKind) else { return nil }
        return AgentsColumn.build(projects: coordinator.knownProjects.projects, roots: repoRoots.roots, selectedId: id)
    }

    /// Asks git for the repo of each known project folder it has not named yet. Part of the panel's
    /// sweep; git runs off the main thread, so the sweep does not wait for it.
    func resolveRepoRoots() {
        guard let coordinator else { return }
        let folders = coordinator.knownProjects.projects.map(\.path)
        let roots = repoRoots
        Task { await roots.resolve(folders) }
    }
}

/// The agents column beside a terminal in `paneWidth` points, or nothing: for a session whose agent's
/// column is off, and where it would leave the terminal too narrow.
struct AgentsColumnHost: View {
    let model: AppModel
    /// The session whose terminal shows here; nil while it shows elsewhere or is no session's.
    let sessionId: String?
    let paneWidth: CGFloat

    var body: some View {
        if let sessionId, AgentsColumnLayout.fits(paneWidth: paneWidth, cellWidth: TerminalStyle.cellWidth),
           let column = model.agentsColumn(for: sessionId) {
            AgentsColumnView(column: column) { model.focus($0) }
                .padding(.leading, AgentsColumnLayout.gap)
                .transition(.opacity)
        }
    }
}
