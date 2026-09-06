import SwiftUI
import LinkCKit

/// Sheet inspecting active peer agents, claimed files, and shared notes in a project.
struct BlackboardSheet: View {
    let workspacePath: String
    let onDismiss: () -> Void

    @State private var blackboard: Blackboard?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROJECT BLACKBOARD")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)

                    Text((workspacePath as NSString).lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }

                    // Active Agents Section
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "ACTIVE AGENTS (\(blackboard?.activeAgents.count ?? 0))")

                        if let agents = blackboard?.activeAgents, !agents.isEmpty {
                            ForEach(agents) { agent in
                                agentRow(agent)
                            }
                        } else {
                            Text("No peer agents currently active.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 4)
                        }
                    }

                    // Shared Notes Section
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "SHARED NOTES & HANDOFFS (\(blackboard?.sharedNotes.count ?? 0))")

                        if let notes = blackboard?.sharedNotes, !notes.isEmpty {
                            ForEach(notes) { note in
                                noteRow(note)
                            }
                        } else {
                            Text("No shared notes recorded yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 400)
        .background(Color(white: 0.12))
        .onAppear {
            refresh()
        }
    }

    private func agentRow(_ agent: AgentRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                AgentPill(agent: agent.agentKind)
                Text("PID \(agent.pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(agent.status.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(agent.goal)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)

            if !agent.claimedFiles.isEmpty {
                Text("Claimed: \(agent.claimedFiles.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func noteRow(_ note: SharedNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                AgentPill(agent: note.authorAgent)
            }
            Text(note.content)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func refresh() {
        do {
            let store = BlackboardStore(workspaceRoot: workspacePath)
            blackboard = try store.getProjectContext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
