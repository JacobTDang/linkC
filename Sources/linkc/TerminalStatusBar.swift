import SwiftUI
import LinkCKit

/// Sleek status banner displayed above the active terminal showing live agent activity,
/// an OpenAI-style shimmer highlight while active, and integrated micro-chips for spawned subagents.
struct TerminalStatusBar: View {
    let session: Session?
    let activity: String?
    let agents: [AgentRun]
    let onOpenAgent: (AgentRun) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let session {
                AgentPill(agent: session.agentKind)

                statusView(for: session)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .shimmerHighlight(isWorking: session.state.bucket == .active)

                Spacer(minLength: 4)

                if !agents.isEmpty {
                    subagentChips
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func statusView(for session: Session) -> some View {
        if let activity, !activity.isEmpty {
            Text(activity)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if session.state == .working {
            Text("Thinking…")
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        } else if session.state.bucket == .needsYou {
            Text("Waiting for input")
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        } else {
            Text("Ready")
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var subagentChips: some View {
        HStack(spacing: 6) {
            ForEach(agents) { agent in
                Button {
                    onOpenAgent(agent)
                } label: {
                    HStack(spacing: 5) {
                        if let type = agent.type, !type.isEmpty {
                            Text(type.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(agent.description)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 140)
                        if agent.isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Theme.statusRunning)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(agent.isRunning ? "Working — output arrives when it finishes" : "Read this agent's report")
            }
        }
    }
}
