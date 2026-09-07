import SwiftUI
import LinkCKit

/// Sleek status banner displayed above the active terminal showing the active agent pill,
/// the session title, live working activity message in native brand color, and integrated micro-chips for spawned subagents.
struct TerminalStatusBar: View {
    let session: Session?
    let activity: String?
    let agents: [AgentRun]
    let onOpenAgent: (AgentRun) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let session {
                AgentPill(agent: session.agentKind)

                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(2)

                statusView(for: session)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if !agents.isEmpty {
                    subagentChips
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 28)
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
        let isWorking = session.state.bucket == .active || (activity != nil && !activity!.isEmpty)

        if isWorking {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 16, height: 16)
                    Image(systemName: activityIcon(for: activity))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                Text(activity ?? "Thinking…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .smoothShimmer(isWorking: true)
            }
        } else if session.state.bucket == .needsYou {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Theme.statusNeedsYou.opacity(0.2))
                        .frame(width: 16, height: 16)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.statusNeedsYou)
                }
                Text(session.state == .waitingPermission ? (activity ?? "Permission required") : "Waiting for input")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.statusNeedsYou)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 5, height: 5)
                Text("Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
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
