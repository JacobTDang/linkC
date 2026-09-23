import SwiftUI
import LinkCKit

/// Rich project-level dashboard sheet inspecting dialogue, claimed files, deliverables, and shared notes.
struct ProjectDashboardSheet: View {
    let workspacePath: String
    let model: AppModel
    let onDismiss: () -> Void

    @State private var dashboardData: ProjectDashboardData?
    @State private var selectedTab: Tab = .timeline

    enum Tab: String, CaseIterable {
        case timeline = "Dialogue & Tasks"
        case files = "Files & Impact"
        case notes = "Shared Notes"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PROJECT DASHBOARD")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                        Text((workspacePath as NSString).lastPathComponent)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer(minLength: 12)
                    Button("Done", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            presenceStrip(dashboardData?.dossiers ?? [])

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
        .frame(width: 600, height: 520)
        .background(Color(white: 0.12))
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    /// Who is in this project right now: one line per live agent — colour mark, agent, what it is
    /// doing, and a way into its terminal. Presence belongs here, not in the event timeline.
    private func presenceStrip(_ dossiers: [AgentContributionDossier]) -> some View {
        let live = dossiers.filter { $0.activeSessionId != nil }
        return Group {
            if !live.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(live) { dossier in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.agentColor(dossier.agent))
                                .frame(width: 7, height: 7)
                            Text(dossier.agent.shortName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            if let activity = dossier.liveActivity, !activity.isEmpty {
                                Text(activity)
                                    .font(.system(size: 11))
                                    .foregroundStyle(dossier.status == "working" ? Theme.textSecondary : Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .smoothShimmer(isWorking: dossier.status == "working")
                            }
                            Spacer(minLength: 8)
                            Text(dossier.status)
                                .font(.system(size: 10))
                                .foregroundStyle(dossier.status == "working" ? Theme.statusRunning : Theme.textTertiary)
                            if let sessionId = dossier.activeSessionId {
                                Button("Open") {
                                    model.focus(sessionId)
                                    onDismiss()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .help("Open \(dossier.agent.shortName)'s terminal")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }
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
                    AgentActivityTimelineCard(item: item)
                }
            }
        }
    }

    private func filesSection(_ dossiers: [AgentContributionDossier]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if dossiers.isEmpty {
                Text("No agent dossiers or file claims yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(dossiers) { dossier in
                    AgentDossierCard(dossier: dossier) { sid in
                        model.focus(sid)
                        onDismiss()
                    }
                }
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
                            .lineLimit(3)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
                }
            }
        }
    }

    private func refresh() async {
        guard let coord = model.coordinator else { return }
        dashboardData = await coord.fetchProjectDashboardAsync(workspacePath: workspacePath)
    }
}
