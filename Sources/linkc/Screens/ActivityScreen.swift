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
        AgentActivityTimelineCard(item: item)
    }

    private func dossiersView(dossiers: [AgentContributionDossier]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(dossiers) { dossier in
                dossierCard(dossier)
            }
        }
    }

    private func dossierCard(_ dossier: AgentContributionDossier) -> some View {
        AgentDossierCard(dossier: dossier) { sid in
            model.focus(sid)
        }
    }
}

// MARK: - Shared Dashboard Components

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return CGSize(width: totalWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }
    }
}

struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
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
}

struct AgentActivityKindBadge: View {
    let kind: AgentActivityKind

    var body: some View {
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

struct AgentDossierCard: View {
    let dossier: AgentContributionDossier
    var onOpenTerminal: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: AgentPill, live activity phrase with .smoothShimmer(isWorking: dossier.status == "working"), status tag, and prominent Button("Open Terminal") when activeSessionId != nil.
            HStack(spacing: 8) {
                AgentPill(agent: dossier.agent)

                if let act = dossier.liveActivity, !act.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: activityIcon(for: act))
                            .font(.system(size: 10))
                            .foregroundStyle(dossier.status == "working" ? Theme.accent : Theme.textTertiary)
                        Text(act)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(dossier.status == "working" ? Theme.accent : Theme.textSecondary)
                            .lineLimit(1)
                            .smoothShimmer(isWorking: dossier.status == "working")
                    }
                }

                Text(dossier.status.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(dossier.status == "working" ? Theme.statusRunning.opacity(0.15) : Color.white.opacity(0.06))
                    .foregroundStyle(dossier.status == "working" ? Theme.statusRunning : Theme.textTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()

                if let sid = dossier.activeSessionId, let onOpenTerminal {
                    Button("Open Terminal") {
                        onOpenTerminal(sid)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Metrics row: [X Tasks Done] · [Y Files Claimed] · [Z Modified in Git]
            HStack(spacing: 8) {
                MetricPill(title: "Tasks Done", value: "\(dossier.completedTasksCount)")
                MetricPill(title: "Files Claimed", value: "\(dossier.claimedFiles.count)")
                MetricPill(title: "Modified in Git", value: "\(dossier.modifiedFiles.count)")
            }

            // Formatted Terminal Thoughts Well
            if let thoughts = dossier.lastDeliverable, !thoughts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LATEST TERMINAL THOUGHTS / OUTPUT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    Text(thoughts)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(6)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                }
            }

            // Modified Files List
            if !dossier.modifiedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FILES MODIFIED IN WORKSPACE (\(dossier.modifiedFiles.count))")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 4) {
                        ForEach(dossier.modifiedFiles.prefix(8), id: \.self) { file in
                            Text(file)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if dossier.modifiedFiles.count > 8 {
                            Text("+\(dossier.modifiedFiles.count - 8) more")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }

            // Claimed Files List
            if !dossier.claimedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FILES CLAIMED (\(dossier.claimedFiles.count))")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 4) {
                        ForEach(dossier.claimedFiles.prefix(8), id: \.self) { file in
                            Text(file)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if dossier.claimedFiles.count > 8 {
                            Text("+\(dossier.claimedFiles.count - 8) more")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

struct AgentActivityTimelineCard: View {
    let item: AgentActivityItem

    var body: some View {
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
                AgentActivityKindBadge(kind: item.kind)
                Text(AgeFormat.compact(from: item.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
            }

            if !item.claimedFiles.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(item.claimedFiles, id: \.self) { file in
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 8))
                            Text(file)
                                .font(.system(size: 9.5, design: .monospaced))
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

