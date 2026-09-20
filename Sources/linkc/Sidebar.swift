import SwiftUI
import AppKit
import LinkCKit

/// The Codex-style sidebar: brand row, navigation, then Projects (sessions nested under each),
/// Terminals, Servers, Cloud, Earlier, and a pinned footer. Plain rows, no cards.
struct Sidebar: View {
    let model: AppModel
    /// Whether the sidebar sits beside a right pane (wide panel) rather than filling it alone
    /// (narrow panel, session/screen replaces it). Only the split layout can show the launcher
    /// beside an empty selection — in the narrow layout an empty selection means the sidebar
    /// itself is on screen, not the launcher.
    var isSplit: Bool

    @State private var inspectingWorkspace: String?

    var body: some View {
        VStack(spacing: 0) {
            BrandRow(model: model)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    NavSection(model: model, isSplit: isSplit)
                    // Ages and states tick once a second while the sidebar is on screen.
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        ProjectsSection(model: model, now: context.date) { inspectingWorkspace = $0 }
                    }
                    if !model.shellRows.isEmpty {
                        TerminalsSidebarSection(model: model)
                    }
                    if let running = model.serverSummary {
                        CollapsibleSection(title: "Servers", trailing: "\(running) running",
                                           section: .servers, state: model.sidebarState) {
                            ServersSection(model: model)
                        }
                    }
                    if let rows = model.cloudSummary {
                        CollapsibleSection(title: "Cloud", trailing: "\(rows)",
                                           section: .cloud, state: model.sidebarState) {
                            CloudSection(model: model)
                        }
                    }
                    UsageSection(model: model)
                    if !model.restorables.isEmpty || !model.restorableShells.isEmpty {
                        EarlierSidebarSection(model: model)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            SidebarFooter(model: model)
        }
        .sheet(isPresented: Binding(
            get: { inspectingWorkspace != nil },
            set: { if !$0 { inspectingWorkspace = nil } }
        )) {
            if let path = inspectingWorkspace {
                ProjectDashboardSheet(workspacePath: path, model: model) { inspectingWorkspace = nil }
            }
        }
    }
}

// MARK: - Rows

/// One plain sidebar row: a 16pt leading glyph, the title, trailing content. A soft pill marks the
/// selected row; hover gets a fainter one. `trailing` receives the hover flag so rows can reveal
/// their actions.
struct SidebarRow<Leading: View, Trailing: View>: View {
    let title: String
    var titleColor: Color = Theme.textPrimary
    var isSelected: Bool = false
    var indent: CGFloat = 0
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: (_ hovering: Bool) -> Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Only the glyph and title are the row's button. Hover controls in `trailing` sit
            // beside it, never inside it, so clicking one can never also run the row's action.
            Button(action: action) {
                HStack(spacing: 8) {
                    leading()
                        .frame(width: 16)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing(hovering)
                .fixedSize()
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.09) : (hovering ? Theme.hover : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help(help ?? title)
    }
}

/// A small hover action glyph inside a row.
private struct RowGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}

/// The agent's color as a small rounded square — how a session row says which agent it is.
private struct AgentMark: View {
    let agent: AgentKind
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Theme.agentColor(agent).opacity(dimmed ? 0.6 : 1))
            .frame(width: 7, height: 7)
    }
}

/// A dim section label; when collapsible, a chevron and a tap to open or close it.
private struct SectionLabel: View {
    let title: String
    var trailing: String? = nil
    var collapsible = false
    var isOpen = true
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if collapsible {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing).monospacedDigit()
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
    }
}

/// A section whose label opens and closes it; the open/closed state is remembered.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    let trailing: String?
    let section: SidebarState.Section
    let state: SidebarState
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(
                title: title, trailing: trailing, collapsible: true,
                isOpen: state.isOpen(section), onToggle: { state.toggle(section) })
            if state.isOpen(section) {
                content()
            }
        }
    }
}

// MARK: - Brand and navigation

private struct BrandRow: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text("linkC")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            LauncherMenu(model: model)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct NavRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    var indent: CGFloat = 0
    let action: () -> Void

    var body: some View {
        SidebarRow(title: title, isSelected: isSelected, indent: indent, action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        } trailing: { _ in
            EmptyView()
        }
    }
}

private struct NavSection: View {
    let model: AppModel
    let isSplit: Bool

    var body: some View {
        let screen = model.activeScreen
        let showsLauncher = screen == .newSession || (isSplit && screen == nil && model.selectedId == nil)
        VStack(alignment: .leading, spacing: 1) {
            NavRow(icon: "plus", title: "New session", isSelected: showsLauncher) { model.open(.newSession) }
            NavRow(icon: "bubble.left.and.text.bubble.right", title: "Activity", isSelected: screen == .activity) {
                model.open(.activity)
            }
            NavRow(icon: "wand.and.stars", title: "Skills", isSelected: screen == .skills) { model.open(.skills) }
            NavRow(icon: "server.rack", title: "MCP servers", isSelected: screen == .mcpServers) {
                model.open(.mcpServers)
            }
            NavRow(icon: "ellipsis", title: "More", isSelected: false) { model.sidebarState.toggle(.more) }
            if model.sidebarState.isOpen(.more) {
                NavRow(icon: "shippingbox", title: "Tool servers", isSelected: screen == .toolServers, indent: 16) {
                    model.open(.toolServers)
                }
                NavRow(icon: "terminal", title: "Terminals", isSelected: screen == .terminals, indent: 16) {
                    model.open(.terminals)
                }
                NavRow(icon: "gearshape", title: "Settings", isSelected: screen == .settings, indent: 16) {
                    model.open(.settings)
                }
            }
        }
    }
}

// MARK: - Projects

private struct ProjectsSection: View {
    let model: AppModel
    let now: Date
    let onInspect: (String) -> Void

    var body: some View {
        let projects = model.sidebarProjects(now: now)
        VStack(alignment: .leading, spacing: 1) {
            if !projects.isEmpty {
                SectionLabel(title: "Projects")
            }
            ForEach(projects) { project in
                ProjectRow(project: project, model: model) { onInspect(project.path) }
                if project.isExpanded {
                    ForEach(project.sessions) { row in
                        SessionRow(row: row, isSelected: row.id == model.selectedId, model: model)
                    }
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: SidebarProject
    let model: AppModel
    let onInspect: () -> Void

    var body: some View {
        SidebarRow(
            title: project.name,
            help: (project.path as NSString).abbreviatingWithTildeInPath,
            action: { model.sidebarState.setExpanded(project.path, !project.isExpanded) }
        ) {
            Image(systemName: project.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        } trailing: { hovering in
            HStack(spacing: 6) {
                if hovering {
                    Menu {
                        ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                            Button("Add \(kind.displayName)") { model.spawnTeammate(in: project.path, agent: kind) }
                        }
                    } label: {
                        RowGlyph(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an agent to \(project.name)")
                    Menu {
                        Button("Blackboard & handoff") { onInspect() }
                        Divider()
                        Button("Stop all sessions") {
                            for session in project.sessions { model.stop(session.id) }
                        }
                    } label: {
                        RowGlyph(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More for \(project.name)")
                }
                ProjectDotView(dot: project.dot)
            }
        }
    }
}

private struct ProjectDotView: View {
    let dot: ProjectDot

    var body: some View {
        switch dot {
        case .none:
            Color.clear.frame(width: 6, height: 6)
        case .working:
            Circle()
                .fill(Theme.statusRunning)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.statusRunning.opacity(0.8), radius: 3)
        case .attention:
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
        }
    }
}

private struct SessionRow: View {
    let row: SidebarSessionRow
    let isSelected: Bool
    let model: AppModel

    var body: some View {
        SidebarRow(
            title: row.title,
            isSelected: isSelected,
            indent: 18,
            help: "\(row.agentKind.displayName) — \(row.title)",
            action: { model.focus(row.id) }
        ) {
            AgentMark(agent: row.agentKind)
        } trailing: { hovering in
            HStack(spacing: 6) {
                Text(row.status.text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(color(for: row.status.tone))
                if hovering {
                    Button { model.stop(row.id) } label: { RowGlyph(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Stop this session")
                }
            }
        }
    }

    private func color(for tone: SessionRowStatus.Tone) -> Color {
        switch tone {
        case .quiet: return Theme.textTertiary
        case .working: return Theme.statusRunning
        case .attention: return Theme.accent
        case .error: return Theme.statusError
        }
    }
}

// MARK: - Terminals

private struct TerminalsSidebarSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(title: "Terminals")
            ForEach(model.shellRows) { row in
                ShellSidebarRow(row: row, isSelected: row.id == model.selectedId, model: model)
            }
        }
    }
}

private struct ShellSidebarRow: View {
    let row: ShellRow
    let isSelected: Bool
    let model: AppModel

    private var isRunning: Bool { row.state == .running }

    private var dotColor: Color {
        switch row.state {
        case .running: return Theme.statusRunning
        case .exited(let code): return code == 0 ? Theme.textTertiary : Theme.statusError
        }
    }

    var body: some View {
        SidebarRow(
            title: row.title,
            titleColor: isRunning ? Theme.textPrimary : Theme.textSecondary,
            isSelected: isSelected,
            help: isRunning ? "Open \(row.title)" : "View \(row.title)'s last output",
            action: { model.focus(row.id) }
        ) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        } trailing: { hovering in
            HStack(spacing: 6) {
                if hovering {
                    if isRunning {
                        Button { model.stopShell(row.id) } label: { RowGlyph(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("Stop terminal")
                    } else {
                        Button { model.relaunchShell(row) } label: { RowGlyph(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                            .help("Open a fresh shell in this folder")
                        Button { model.dismissShell(row.id) } label: { RowGlyph(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                    }
                }
                Circle().fill(dotColor).frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Earlier

private struct EarlierSidebarSection: View {
    let model: AppModel

    var body: some View {
        let count = model.restorables.count + model.restorableShells.count
        CollapsibleSection(title: "Earlier", trailing: "\(count)", section: .earlier, state: model.sidebarState) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.restorables) { session in
                    EarlierSessionRow(session: session, model: model)
                }
                ForEach(model.restorableShells) { shell in
                    EarlierShellRow(shell: shell, model: model)
                }
                if model.restorables.count > 1 {
                    Button { model.restoreAll() } label: {
                        Text("Restore all")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 32)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Restore every previous session")
                }
            }
        }
    }
}

private struct EarlierSessionRow: View {
    let session: RestorableSession
    let model: AppModel

    var body: some View {
        SidebarRow(
            title: session.title,
            titleColor: Theme.textSecondary,
            help: "Restore \(session.agentKind.displayName) in \((session.cwd as NSString).abbreviatingWithTildeInPath)",
            action: { model.restore(session) }
        ) {
            AgentMark(agent: session.agentKind, dimmed: true)
        } trailing: { hovering in
            HStack(spacing: 6) {
                if let ended = session.endedLabel(now: Date()) {
                    Text(ended)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                if hovering {
                    Button { model.dismiss(session) } label: { RowGlyph(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                }
            }
        }
        .contextMenu {
            ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                Button("Restore as \(kind.displayName)") { model.restore(session, as: kind) }
            }
        }
    }
}

private struct EarlierShellRow: View {
    let shell: RestorableShell
    let model: AppModel

    var body: some View {
        SidebarRow(
            title: shell.title,
            titleColor: Theme.textSecondary,
            help: shell.command.map { "Re-run: \($0)" } ?? "Open a fresh shell in this folder",
            action: { model.restoreShell(shell) }
        ) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        } trailing: { hovering in
            if hovering {
                Button { model.forgetShell(shell) } label: { RowGlyph(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Forget this terminal")
            }
        }
    }
}

// MARK: - Usage

/// What every agent has left. Re-reads its inputs every 30 s so the reset times count down;
/// the figures themselves are refreshed by the app's own timers.
private struct UsageSection: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let result = model.usageRows(now: context.date)
            CollapsibleSection(
                title: "Usage", trailing: result.headline, section: .usage, state: model.sidebarState
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(result.rows) { row in
                        UsageRowView(row: row)
                    }
                    if !result.unknown.isEmpty {
                        Text(result.unknown.map { $0.agent.shortName }.joined(separator: ", ") + " — no usage data")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .help(result.unknown.map { "\($0.agent.shortName): \($0.reason)" }
                                .joined(separator: "\n"))
                    }
                }
            }
        }
    }
}

/// One agent's usage line: its mark, its name, and the figure. A stale reading dims rather than
/// disappears — knowing the last reading, and that it is old, beats knowing nothing.
private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.agentColor(row.agent).opacity(row.isStale ? 0.5 : 1))
                .frame(width: 7, height: 7)
            Text(row.agent.shortName)
                .font(.system(size: 12))
                .foregroundStyle(row.isStale ? Theme.textTertiary : Theme.textSecondary)
            Spacer(minLength: 6)
            Text(row.text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(figureColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .help(row.help.isEmpty ? row.agent.displayName : row.help)
    }

    private var figureColor: Color {
        // Coral outranks dimming: a row can be coral and stale at once — the 5-hour window it
        // leads with has rolled over while another window is live and over the threshold. The
        // figure that is actually urgent must not be greyed out for the stale one's sake.
        if row.isCoral { return Theme.accent }
        return row.isStale ? Theme.textTertiary.opacity(0.7) : Theme.textTertiary
    }
}

// MARK: - Footer

/// Plan usage on the left, and a round coral install button when a fresh build is waiting.
private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        let usage = model.preferences.showsUsageFooter ? model.windowUsageLabel : nil
        if usage != nil || model.updateAvailable != nil {
            HStack(spacing: 8) {
                if let usage {
                    Text(usage)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let update = model.updateAvailable {
                    Button { model.installUpdate() } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Install & restart · build \(update.fromBuild) → \(update.toBuild)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            }
        }
    }
}
