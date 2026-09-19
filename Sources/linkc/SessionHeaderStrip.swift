import SwiftUI
import LinkCKit

/// The one line above an open terminal: what used to sit on each card. Agent mark, title,
/// "<Agent> · <project>", a subagents chip (a popover of the runs; picking one opens the reader),
/// the session's spend, a 2pt context bar, and the project's collision warning.
struct SessionHeaderStrip: View {
    let model: AppModel
    let session: Session
    let onBack: (() -> Void)?
    let onOpenAgent: (AgentRun) -> Void

    @State private var showsAgents = false

    var body: some View {
        let agents = model.visibleAgents(session.id)
        let title = model.sessionTitles[session.id] ?? session.title
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let onBack {
                    ChromeButton(systemName: "chevron.left", help: "Back", action: onBack)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.agentColor(session.agentKind))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("\(session.agentKind.shortName) · \(URL(fileURLWithPath: session.cwd).lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !agents.isEmpty {
                    Button { showsAgents.toggle() } label: {
                        Text(agents.count == 1 ? "1 subagent ▾" : "\(agents.count) subagents ▾")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsAgents, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(agents) { agent in
                                AgentLine(agent: agent)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        showsAgents = false
                                        onOpenAgent(agent)
                                    }
                            }
                        }
                        .padding(12)
                        .frame(width: 320)
                    }
                }
                if let label = model.selectedUsageLabel {
                    Text(label)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            if let fill = model.contextFill(session.id) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(fill > 0.75 ? Theme.contextWarn : Color.white.opacity(0.3))
                            .frame(width: geo.size.width * fill)
                    }
                }
                .frame(height: 2)
            }
            if let collisions = model.swarm(for: session.cwd)?.collisions, !collisions.isEmpty {
                CollisionBanner(collisions: collisions)
            }
        }
    }
}

/// The line above an open dev shell: its title and folder, and the back button in a narrow panel.
/// Built from the shell's row, which the app's sweep already samples — never a process scan.
struct ShellHeaderStrip: View {
    let row: ShellRow
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                ChromeButton(systemName: "chevron.left", help: "Back", action: onBack)
            }
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text(row.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(URL(fileURLWithPath: row.cwd).lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
    }
}
