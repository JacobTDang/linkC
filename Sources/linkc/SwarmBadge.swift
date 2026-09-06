import SwiftUI
import LinkCKit

/// Compact micro-badge indicating multiple concurrent agents in a project workspace.
struct SwarmBadge: View {
    let swarm: ProjectSwarm
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

    private func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .claude: return Color(red: 217/255, green: 119/255, blue: 87/255)
        case .agy: return Color(red: 122/255, green: 162/255, blue: 247/255)
        case .cursor: return Color(red: 0/255, green: 229/255, blue: 255/255)
        case .codex: return Color(red: 16/255, green: 163/255, blue: 127/255)
        case .shell: return Color(white: 0.55)
        }
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)

                Text("\(swarm.activeAgents.count) AGENTS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 2) {
                    ForEach(swarm.activeAgents, id: \.self) { agent in
                        Circle()
                            .fill(agentColor(agent))
                            .frame(width: 5, height: 5)
                    }
                }

                if !swarm.collisions.isEmpty {
                    Circle()
                        .fill(Theme.contextWarn)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(hovering ? Theme.hover : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(swarm.collisions.isEmpty ? Color.white.opacity(0.08) : Theme.contextWarn.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(swarm.collisions.isEmpty ? "Multi-agent swarm active" : "Warning: active file collisions detected")
    }
}
