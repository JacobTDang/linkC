import Foundation
import LinkCKit

/// The sidebar's live inputs. Reads only — the one writer, `sampleSidebar`, runs from the
/// once-a-second shell sweep, never from a view body.
extension AppModel {
    /// The session whose terminal is actually on screen: selected, no screen layered over it,
    /// panel visible.
    var onScreenSessionId: String? {
        guard panelVisible, activeScreen == nil else { return nil }
        return selectedId
    }

    /// Every live session's row title, keyed by session id.
    var sessionTitles: [String: String] {
        SessionTitles.resolve(
            sessions: sessions,
            claudeTitle: { usage.sessionTitle($0) },
            heldTask: { session in
                inbox(for: session.cwd).flatMap { SessionTitles.heldTask(for: session, in: $0.tasks) }
            }
        )
    }

    func rowStatus(_ session: Session, now: Date = Date()) -> SessionRowStatus {
        attention.status(
            for: session,
            onScreen: session.id == onScreenSessionId,
            rateLimited: agentLimit(for: session) != nil,
            now: now
        )
    }

    func sidebarProjects(now: Date = Date()) -> [SidebarProject] {
        let titles = sessionTitles
        let inputs = sessions.map { session in
            SidebarModel.Input(
                session: session,
                title: titles[session.id] ?? session.agentKind.shortName,
                status: rowStatus(session, now: now),
                hasRunningSubagents: visibleAgents(session.id, now: now).contains(where: \.isRunning)
            )
        }
        return SidebarModel.projects(
            inputs: inputs,
            order: sidebarState.projectOrder,
            expandOverrides: sidebarState.expandOverrides,
            selectedId: selectedId
        )
    }

    /// Sessions that want the user — drives the menu-bar tint.
    var attentionCount: Int {
        sessions.count { rowStatus($0).isCoral }
    }

    /// Running compose projects plus standalone containers, or nil when the Servers section hides.
    var serverSummary: Int? {
        let running = runningProjectsByPower.count + runningStandaloneByPower.count
        return (running > 0 || dockerVmCpu != nil) ? running : nil
    }

    /// Oracle, Supabase, and watched rows, or nil when the Cloud section hides.
    var cloudSummary: Int? {
        let rows = cloudInstances.count + supabaseProjects.count + configuredEndpoints.count
        return (rows > 0 || supabaseNeedsLogin || !cloudErrors.isEmpty) ? rows : nil
    }

    /// Once a second: forget ended sessions, mark what is on screen as seen, keep the project
    /// order, and expand projects that just turned coral.
    func sampleSidebar() {
        let now = Date()
        attention.retain(only: Set(sessions.map(\.id)))
        markOnScreenSeen(at: now)
        sidebarState.noteProjects(ProjectGroup.group(sessions: sessions).map(\.workspacePath))
        let coral = sidebarProjects(now: now).filter { $0.dot == .attention }.map(\.path)
        sidebarState.noteCoral(Set(coral))
    }

    /// Mark the on-screen session seen. Also called just before navigation moves it off screen,
    /// so a turn that finished while the user watched never reads as unseen afterwards.
    func markOnScreenSeen(at now: Date = Date()) {
        guard let id = onScreenSessionId, let session = sessions.first(where: { $0.id == id }) else { return }
        attention.markSeen(session, at: now)
    }
}
