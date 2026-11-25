import LinkCKit
import SwiftUI

extension AppModel {
    /// The agent cards of session `id`'s repo, beside its terminal or in the toggle's popover. Built from
    /// the list the coordinator publishes and the repos git already named: it reads, never asks.
    func agentsColumn(for id: String) -> AgentsColumn? {
        guard let coordinator, sessions.contains(where: { $0.id == id }) else { return nil }
        return AgentsColumn.build(projects: coordinator.knownProjects.projects, roots: repoRoots.roots, selectedId: id)
    }

    /// Where the cards show for session `id`'s terminal in a pane `paneWidth` points wide; nil for no
    /// session, a terminal that is no session's, or a pane not measured yet.
    func agentsColumnPlacement(for id: String?, paneWidth: CGFloat?, backingScale: CGFloat) -> AgentsColumnPlacement? {
        guard let id, let paneWidth, let session = sessions.first(where: { $0.id == id }) else { return nil }
        return AgentsColumnLayout.placement(paneWidth: paneWidth, grid: TerminalStyle.grid(backingScale: backingScale),
                                            isOn: preferences.showsAgentsColumn(for: session.agentKind))
    }

    /// A click on session `id`'s card, among the cards beside session `beside`; `inWindow` says they are
    /// in a torn-off window. A card whose terminal is in the panel brings the panel up.
    func openAgentCard(_ id: String, beside: String, inWindow: Bool) {
        switch AgentCardClick.of(card: id, besideSession: beside, inWindow: inWindow, cardInWindow: host(of: id) != nil) {
        case .acknowledge:
            acknowledge(id)
        case .focus:
            focus(id)
        case .focusShowingPanel:
            focus(id)
            onShowPanel?()
        }
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

/// The agents column beside a terminal, while its placement puts it there.
struct AgentsColumnHost: View {
    let model: AppModel
    /// The session whose terminal shows here; nil while it shows elsewhere or is no session's.
    let sessionId: String?
    let placement: AgentsColumnPlacement?
    /// The column is in a torn-off window.
    let inWindow: Bool

    var body: some View {
        if let sessionId, placement == .beside, let column = model.agentsColumn(for: sessionId) {
            AgentsColumnView(column: column, fillsHeight: true) {
                model.openAgentCard($0, beside: sessionId, inWindow: inWindow)
            }
            .padding(.leading, AgentsColumnLayout.gap)
            .transition(.opacity)
        }
    }
}

/// The agents column's toggle. Where the column fits it shows or hides the column beside every terminal
/// of this agent; where it does not, it opens the same cards in a popover. Its glyph says which: a
/// sidebar, lit while the column shows, or a stack of cards, lit while the popover is open.
struct AgentsColumnToggle: View {
    let model: AppModel
    let sessionId: String
    let agent: AgentKind
    let placement: AgentsColumnPlacement
    /// The toggle is in a torn-off window.
    let inWindow: Bool

    @State private var showsPopover = false
    @State private var hovering = false

    private var isLit: Bool { placement == .beside || showsPopover }

    var body: some View {
        Button(action: click) {
            Image(systemName: placement == .popover ? "rectangle.stack" : "sidebar.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering || isLit ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering || showsPopover ? Theme.hover : Color.clear))
                .contentShape(Circle())
                .animation(Theme.hoverEase, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            AgentsPopover(model: model, sessionId: sessionId, inWindow: inWindow) { showsPopover = false }
        }
        // Room for the column again: the cards show beside the terminal, not in the popover too.
        .onChange(of: placement) { _, now in
            if now != .popover { showsPopover = false }
        }
    }

    private var help: String {
        switch placement {
        case .beside: return "Hide linkC agents"
        case .hidden: return "Show linkC agents"
        case .popover: return "Show linkC agents (no room beside the terminal)"
        }
    }

    private func click() {
        switch placement {
        case .beside, .hidden: model.preferences.toggleAgentsColumn(for: agent)
        case .popover: showsPopover.toggle()
        }
    }
}

/// The cards in the toggle's popover. A click on one closes the popover, then opens its session.
private struct AgentsPopover: View {
    let model: AppModel
    let sessionId: String
    let inWindow: Bool
    let close: () -> Void

    var body: some View {
        if let column = model.agentsColumn(for: sessionId) {
            AgentsColumnView(column: column, fillsHeight: false) { id in
                // First: a click that selects another session in the panel would keep this popover open
                // over that session's header.
                close()
                model.openAgentCard(id, beside: sessionId, inWindow: inWindow)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
    }
}
