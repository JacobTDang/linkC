import SwiftUI
import LinkCKit

/// Compact micro-badge showing the active AI CLI agent (CLAUDE, AGY, CURSOR, CODEX, SHELL).
struct AgentPill: View {
    let agent: AgentKind

    private var color: Color {
        Theme.agentColor(agent)
    }

    var body: some View {
        Text(agent.pillText)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(0.25), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .layoutPriority(2)
    }
}
