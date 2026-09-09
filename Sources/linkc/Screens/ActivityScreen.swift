import SwiftUI
import LinkCKit

struct ActivityScreen: View {
    let model: AppModel

    @State private var selectedTab: Tab = .timeline

    enum Tab: String, CaseIterable {
        case timeline = "Timeline"
        case dossiers = "Agent Dossiers"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "AGENT ACTIVITY & DASHBOARD") {
                Picker("View Mode", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            Divider()

            if let data = model.globalDashboardData, !data.activityItems.isEmpty || !data.dossiers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if selectedTab == .timeline {
                            timelineView(items: data.activityItems)
                        } else {
                            dossiersView(dossiers: data.dossiers)
                        }
                    }
                    .padding(16)
                    .readingColumn()
                }
            } else {
                EmptyHint(
                    title: "No Agent Activity Yet",
                    message: "Cross-agent task delegations, completions, notes, and file contributions will appear here in real time."
                )
            }
        }
        .task {
            await model.refreshDashboard()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if Task.isCancelled { break }
                await model.refreshDashboard()
            }
        }
    }

    private func timelineView(items: [AgentActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                activityCard(item)
            }
        }
    }

    private func activityCard(_ item: AgentActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentPill(agent: item.fromAgent)
                if let to = item.toAgent {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    AgentPill(agent: to)
                }
                Spacer()
                kindBadge(item.kind)
                Text(AgeFormat.compact(from: item.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !item.claimedFiles.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.claimedFiles.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func dossiersView(dossiers: [AgentContributionDossier]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(dossiers) { dossier in
                dossierCard(dossier)
            }
        }
    }

    private func dossierCard(_ dossier: AgentContributionDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentPill(agent: dossier.agent)
                if let act = dossier.liveActivity, dossier.status == "working" {
                    Text(act)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .smoothShimmer(isWorking: true)
                } else {
                    Text(dossier.status.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if let sid = dossier.activeSessionId {
                    Button("Open Terminal") {
                        model.focus(sid)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                metricPill(title: "Completed", value: "\(dossier.completedTasksCount)")
                metricPill(title: "Claimed Files", value: "\(dossier.claimedFiles.count)")
                metricPill(title: "Modified", value: "\(dossier.modifiedFiles.count)")
            }

            if !dossier.claimedFiles.isEmpty {
                Text("Files Claimed: \(dossier.claimedFiles.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            if let deliverable = dossier.lastDeliverable, !deliverable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest Deliverable Output:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(deliverable)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func metricPill(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func kindBadge(_ kind: AgentActivityKind) -> some View {
        let (text, color): (String, Color) = {
            switch kind {
            case .completedTask: return ("COMPLETED", Theme.statusRunning)
            case .delegatedTask: return ("DELEGATED", Theme.accent)
            case .intentBroadcast: return ("GOAL", Color(red: 122/255, green: 162/255, blue: 247/255))
            case .sharedNote: return ("NOTE", Color(white: 0.7))
            case .rateLimited: return ("LIMIT", Theme.statusError)
            }
        }()
        return Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
