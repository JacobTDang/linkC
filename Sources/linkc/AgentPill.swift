import SwiftUI
import LinkCKit

/// Compact micro-badge showing the active AI CLI agent (CLAUDE, AGY, CURSOR, CODEX, SHELL).
struct AgentPill: View {
    let agent: AgentKind
    var isSelected: Bool = false

    init(agent: AgentKind, isSelected: Bool = false) {
        self.agent = agent
        self.isSelected = isSelected
    }

    private var color: Color {
        Theme.agentColor(agent)
    }

    var body: some View {
        Text(agent.pillText)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(isSelected ? Color.white : color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(isSelected ? color.opacity(0.85) : color.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSelected ? Color.white.opacity(0.8) : color.opacity(0.25), lineWidth: isSelected ? 1.0 : 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: isSelected ? color.opacity(0.5) : Color.clear, radius: 2)
            .fixedSize()
            .layoutPriority(2)
    }
}
