import SwiftUI
import LinkCKit

/// Rich project-level dashboard sheet inspecting dialogue, claimed files, deliverables, and shared notes.
struct ProjectDashboardSheet: View {
    let workspacePath: String
    let model: AppModel
    let onDismiss: () -> Void

    @State private var dashboardData: ProjectDashboardData?
    @State private var selectedTab: Tab = .timeline
    @State private var refreshTimer: Timer?

    enum Tab: String, CaseIterable {
        case timeline = "Dialogue & Tasks"
        case files = "Files & Impact"
        case notes = "Shared Notes"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROJECT DASHBOARD")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)

                    Text((workspacePath as NSString).lastPathComponent)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let data = dashboardData {
                        if !data.collisions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Active File Conflicts Detected", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.contextWarn)
                                ForEach(data.collisions, id: \.conflictingAgent) { col in
                                    Text("\(col.conflictingAgent.displayName): \(col.conflictingFiles.joined(separator: ", "))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(10)
                            .background(Theme.contextWarn.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        switch selectedTab {
                        case .timeline:
                            timelineSection(data.activityItems)
                        case .files:
                            filesSection(data.dossiers)
                        case .notes:
                            notesSection(data.sharedNotes)
                        }
                    } else {
                        ProgressView()
                            .padding(20)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 460)
        .background(Color(white: 0.12))
        .onAppear {
            refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    refresh()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func timelineSection(_ items: [AgentActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("No inter-agent tasks or messages yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            AgentPill(agent: item.fromAgent)
                            if let to = item.toAgent {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                AgentPill(agent: to)
                            }
                            Spacer()
                            Text(AgeFormat.compact(from: item.timestamp))
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func filesSection(_ dossiers: [AgentContributionDossier]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(dossiers) { dossier in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        AgentPill(agent: dossier.agent)
                        Spacer()
                        Text("\(dossier.completedTasksCount) tasks done")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.statusRunning)
                    }
                    if !dossier.claimedFiles.isEmpty {
                        Text("Claimed: \(dossier.claimedFiles.joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if !dossier.modifiedFiles.isEmpty {
                        Text("Modified in git: \(dossier.modifiedFiles.joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func notesSection(_ notes: [SharedNote]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if notes.isEmpty {
                Text("No shared notes recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(notes) { note in
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
                }
            }
        }
    }

    private func refresh() {
        dashboardData = model.coordinator?.fetchProjectDashboard(workspacePath: workspacePath)
    }
}
