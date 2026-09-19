import SwiftUI
import LinkCKit

/// One agent in the header strip's subagents popover: type badge, its own description, age,
/// spinner or done-tick.
struct AgentLine: View {
    let agent: AgentRun

    var body: some View {
        HStack(spacing: 7) {
            if let type = agent.type {
                Text(type.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            }
            Text(agent.description)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(AgeFormat.compact(from: agent.startedAt, to: agent.endedAt ?? Date()))
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
            if agent.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.statusRunning)
            }
        }
        .padding(.leading, 15)  // room for the type badge, so a row without one still aligns
    }
}


/// An agent's report, readable in place — the skill-reader pattern: local back, selectable
/// monospaced body. A still-running agent shows its identity and age instead of a body.
struct AgentReaderView: View {
    let agent: AgentRun
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ChromeButton(systemName: "chevron.left", help: "Back to terminal", action: onBack)
                Text(agent.description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let type = agent.type {
                    Text(type.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if let result = agent.resultText {
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.9))
                            .selectableText()
                            .fixedSize(horizontal: false, vertical: true)
                    } else if agent.isRunning {
                        Text("Still working — \(AgeFormat.compact(from: agent.startedAt)) in. The report lands here when it finishes.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Finished without a text report.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readingColumn()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}
