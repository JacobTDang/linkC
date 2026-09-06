import SwiftUI
import LinkCKit

/// Compact micro-badge showing the active AI CLI agent (CLAUDE, AGY, CURSOR, CODEX, SHELL).
struct AgentPill: View {
    let agent: AgentKind

    private var color: Color {
        switch agent {
        case .claude: return Color(red: 217/255, green: 119/255, blue: 87/255) // #D97757
        case .agy: return Color(red: 122/255, green: 162/255, blue: 247/255)   // #7AA2F7
        case .cursor: return Color(red: 0/255, green: 229/255, blue: 255/255)  // #00E5FF
        case .codex: return Color(red: 16/255, green: 163/255, blue: 127/255)  // #10A37F
        case .shell: return Color(white: 0.55)
        }
    }

    var body: some View {
        Text(agent.pillText)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(0.25), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
