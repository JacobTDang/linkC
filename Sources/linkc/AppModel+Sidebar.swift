import Foundation
import LinkCKit

/// The sidebar's live inputs. Reads only — the writers are `sampleSidebar()` (once a second,
/// from the shell sweep) and `markOnScreenSeen()` (just before the selection, the open screen,
/// or the panel's visibility changes) — never a view body.
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
            rateLimited: session.state == .error && agentLimit(for: session) != nil,
            now: now
        )
    }

    /// The session's current action ("$ swift test", "Thinking…", etc.) while it's working,
    /// and while it's blocked on a permission prompt. Idle sessions never state an absence.
    func currentActivity(_ session: Session) -> String? {
        if let hookActivity = usage.sessionActivity(session.id), !hookActivity.isEmpty {
            return hookActivity
        }
        if let term = coordinator?.terminals.session(id: session.id),
           let liveActivity = term.liveActivityLine(), !liveActivity.isEmpty {
            return liveActivity
        }
        if session.agentKind == .claude, session.state.bucket == .active {
            return "Thinking…"
        }
        if session.state == .waitingPermission {
            return "Permission required"
        }
        return nil
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
        let selectedProject = sessions.first { $0.id == selectedId }
            .map { ($0.cwd as NSString).standardizingPath }
        sidebarState.noteSelectedProject(selectedProject)
        let coral = sidebarProjects(now: now).filter { $0.dot == .attention }.map(\.path)
        sidebarState.noteCoral(Set(coral))
    }

    /// Mark the on-screen session seen. Runs once a second from the sweep, and just before the
    /// selection, the open screen, or the panel's visibility changes, so a turn that finished
    /// while the user watched never reads as unseen afterwards.
    func markOnScreenSeen(at now: Date = Date()) {
        guard let id = onScreenSessionId, let session = sessions.first(where: { $0.id == id }) else { return }
        attention.markSeen(session, at: now)
    }

    /// Checks if a session's agent has an active rate limit recorded in the inbox.
    func agentLimit(for session: Session) -> AgentLimitStatus? {
        let norm = (session.cwd as NSString).standardizingPath
        guard let inbox = inbox(for: norm) else { return nil }
        let now = Date()
        if let limit = inbox.agentLimits.first(where: { $0.agent == session.agentKind }),
           limit.cooldownExpiresAt > now {
            return limit
        }
        return nil
    }

    /// Every agent's most recent live cap across the workspaces that have a session. When an agent
    /// is capped in more than one, the furthest-out cooldown wins: that is when it can work again.
    var agentLimits: [AgentKind: AgentLimitStatus] {
        var latest: [AgentKind: AgentLimitStatus] = [:]
        for path in Set(sessions.map { ($0.cwd as NSString).standardizingPath }) {
            for limit in inbox(for: path)?.agentLimits ?? [] {
                if let existing = latest[limit.agent], existing.cooldownExpiresAt >= limit.cooldownExpiresAt {
                    continue
                }
                latest[limit.agent] = limit
            }
        }
        return latest
    }

    /// The sidebar's Usage section: a row per agent that reports something, the rest listed with
    /// the reason they do not.
    func usageRows(now: Date = Date()) -> UsageRows.Result {
        UsageRows.build(claude: coordinator?.claudeUsage, codex: codexUsage, limits: agentLimits, now: now)
    }
}
