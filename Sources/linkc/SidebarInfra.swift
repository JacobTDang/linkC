import SwiftUI
import AppKit
import LinkCKit

// MARK: - Compact (sidebar) rows

/// The sidebar's infra sections — Terminals, Servers, and Cloud — built from one shared compact
/// row style, marked by a steady `InfraDot` rather than a claude session row's agent logo.

/// The compact rows' shared shell: leading accessory · badge · title · middle · spacer · trailing,
/// and optional subrow underneath, on the plane/hover/tap treatment every sidebar row repeats.
private struct CompactRowShell<Leading: View, Badge: View, Middle: View, Subrow: View, Trailing: View>: View {
    let title: String
    var titleColor: Color = Theme.textPrimary
    var needsYou: Bool = false
    var isSelected: Bool = false
    var dimmed: Bool = false
    /// Whether hover brightens the plane. Dead rows (an exited terminal) stay flat —
    /// they're still tappable for scrollback, but a history row must not read as live.
    var glowsOnHover: Bool = true
    let help: String
    let onTap: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let subrow: () -> Subrow
    @ViewBuilder let trailing: (_ hovering: Bool) -> Trailing

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if Leading.self != EmptyView.self {
                leading()
                    .fixedSize()
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if Badge.self != EmptyView.self {
                        badge()
                            .fixedSize()
                            .layoutPriority(2) // badge is always on the left and never squished
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1) // title truncates if space is constrained
                    middle()
                    Spacer(minLength: 4)
                    trailing(hovering)
                        .fixedSize()
                }
                subrow()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .planeCard(needsYou: needsYou, hovering: (hovering && glowsOnHover) || isSelected)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .padding(.leading, 1)
            }
        }
        .opacity(dimmed ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .animation(Theme.hoverEase, value: isSelected)
        .help(help)
    }
}

/// Convenience init without badge, middle, or subrow.
extension CompactRowShell where Badge == EmptyView, Middle == EmptyView, Subrow == EmptyView {
    init(
        title: String,
        titleColor: Color = Theme.textPrimary,
        needsYou: Bool = false,
        isSelected: Bool = false,
        dimmed: Bool = false,
        glowsOnHover: Bool = true,
        help: String,
        onTap: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping (_ hovering: Bool) -> Trailing
    ) {
        self.init(
            title: title, titleColor: titleColor, needsYou: needsYou, isSelected: isSelected,
            dimmed: dimmed, glowsOnHover: glowsOnHover, help: help, onTap: onTap,
            leading: leading, badge: { EmptyView() }, middle: { EmptyView() }, subrow: { EmptyView() }, trailing: trailing
        )
    }
}

/// Convenience init without badge or subrow (only leading, middle, trailing).
extension CompactRowShell where Badge == EmptyView, Subrow == EmptyView {
    init(
        title: String,
        titleColor: Color = Theme.textPrimary,
        needsYou: Bool = false,
        isSelected: Bool = false,
        dimmed: Bool = false,
        glowsOnHover: Bool = true,
        help: String,
        onTap: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder middle: @escaping () -> Middle,
        @ViewBuilder trailing: @escaping (_ hovering: Bool) -> Trailing
    ) {
        self.init(
            title: title, titleColor: titleColor, needsYou: needsYou, isSelected: isSelected,
            dimmed: dimmed, glowsOnHover: glowsOnHover, help: help, onTap: onTap,
            leading: leading, badge: { EmptyView() }, middle: middle, subrow: { EmptyView() }, trailing: trailing
        )
    }
}

/// The quiet 8pt infra dot in an 18pt box, no glow — terminals, servers, and cloud rows use it
/// as their leading mark. A claude session row uses `AgentLogoView`'s logo instead, with its
/// state carried by the trailing status text's color.
private struct InfraDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .frame(width: 18, height: 18)
    }
}

// MARK: - Servers (sidebar)

/// The sidebar's running-servers section: compose projects with live containers, then
/// standalone running containers, each ranked hottest-first by live CPU — the power proxy
/// (per-container energy doesn't exist on macOS; every container shares one VM). Read-only
/// pointers into the Tool Servers screen; hidden entirely when nothing runs.
struct ServersSection: View {
    let model: AppModel

    var body: some View {
        let projects = model.runningProjectsByPower
        let standalone = model.runningStandaloneByPower
        if !projects.isEmpty || !standalone.isEmpty || model.dockerVmCpu != nil {
            VStack(spacing: 6) {
                // The VM tax leads the section: it's what Docker costs even when every
                // container below reads 0% — the answer to "why does the battery menu
                // still blame Docker?".
                if let vm = model.dockerVmCpu {
                    ServerRow(
                        title: "docker VM",
                        count: nil,
                        cpuPercent: vm,
                        warn: vm >= 100,
                        onOpen: { model.open(.toolServers) }
                    )
                }
                ForEach(projects) { project in
                    ServerRow(
                        title: project.name,
                        count: project.runningCount,
                        cpuPercent: model.projectCpu(project),
                        warn: model.projectHottest(project) >= 100,
                        onOpen: { model.open(.toolServers) }
                    )
                }
                ForEach(standalone) { container in
                    let cpu = model.containerStats(container.id)?.cpuValue ?? 0
                    ServerRow(
                        title: container.name,
                        count: nil,
                        cpuPercent: cpu,
                        warn: cpu >= 100,
                        onOpen: { model.open(.toolServers) }
                    )
                }
            }
        }
    }
}

/// One running server as a quiet row: a steady dot (infra never pulses — urgency is
/// claude's vocabulary), the project or container name, its live-container count, and its
/// CPU share. `warn` golds the figure when a single container crosses a full core — the
/// "this is your battery" signal (a stack's SUM crossing 100 from idle containers is not).
/// Tapping opens the Tool Servers screen for the real controls.
private struct ServerRow: View {
    let title: String
    let count: Int?
    let cpuPercent: Double
    let warn: Bool
    let onOpen: () -> Void

    var body: some View {
        CompactRowShell(title: title, help: "Open Tool Servers", onTap: onOpen) {
            InfraDot(color: Theme.textSecondary)
        } middle: {
            if let count, count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        } trailing: { _ in
            if cpuPercent >= 1 {
                Text("\(Int(cpuPercent.rounded()))%")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(warn ? Theme.contextWarn : Theme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Cloud (sidebar)

/// The sidebar's cloud section — Oracle compute instances through the user's own `oci`
/// CLI (linkC never holds credentials). Hidden entirely when the CLI, config, or
/// instances are absent. The Oracle console is the drill-in: tapping opens it.
struct CloudSection: View {
    let model: AppModel
    /// Only one row expands at a time — the sidebar stays a glance, not a dashboard.
    @State private var expandedId: String?

    var body: some View {
        let instances = model.cloudInstances
        let projects = model.supabaseProjects
        let watched = model.configuredEndpoints
        let needsLogin = model.supabaseNeedsLogin
        let errors = model.cloudErrors
        // Where a row came from is worth saying once per group rather than once per row —
        // the sidebar can't spare the width. Headers appear only when more than one provider
        // is present: a lone group needs no label.
        let groupCount = [!instances.isEmpty, !projects.isEmpty, !watched.isEmpty]
            .count { $0 }
        let showsProviders = groupCount > 1
        if groupCount > 0 || needsLogin || !errors.isEmpty {
            VStack(spacing: 6) {
                if !instances.isEmpty {
                    if showsProviders { ProviderHeader(title: "ORACLE") }
                    ForEach(instances) { instance in
                        CloudRow(
                            instance: instance,
                            region: model.cloudRegion,
                            detail: model.cloudDetail(instance.id),
                            isExpanded: expandedId == instance.id,
                            onTap: {
                                if expandedId == instance.id {
                                    expandedId = nil
                                } else {
                                    expandedId = instance.id
                                    model.loadCloudDetail(instance.id)
                                }
                            },
                            onRefresh: { model.loadCloudDetail(instance.id, force: true) }
                        )
                    }
                }
                if !projects.isEmpty {
                    if showsProviders { ProviderHeader(title: "SUPABASE") }
                    ForEach(projects) { project in
                        SupabaseRow(
                            project: project,
                            health: model.supabaseHealth(project),
                            isExpanded: expandedId == project.id,
                            onTap: { expandedId = expandedId == project.id ? nil : project.id }
                        )
                    }
                }
                if !watched.isEmpty {
                    if showsProviders { ProviderHeader(title: "WATCHED") }
                    ForEach(watched) { endpoint in
                        WatchedServiceRow(
                            endpoint: endpoint,
                            health: model.serviceHealth(endpoint.id)
                        )
                    }
                }
                // Fail loud: an unauthenticated CLI or a failing listing must not render
                // as a silently empty section.
                if needsLogin {
                    CloudNoticeRow(text: "supabase login to list projects", isWarning: false)
                }
                ForEach(errors, id: \.self) { error in
                    CloudNoticeRow(text: error, isWarning: true)
                }
            }
        }
    }
}

/// A quiet one-line notice under the cloud rows — an invitation ("supabase login…") or a
/// failure. Without it, a provider that can't answer renders as nothing at all.
private struct CloudNoticeRow: View {
    let text: String
    let isWarning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 9))
                .foregroundStyle(isWarning ? Theme.statusError : Theme.textTertiary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(isWarning ? Theme.statusError : Theme.textTertiary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// A provider label inside CLOUD — deliberately quieter and smaller than `SectionHeader`
/// so the section title still reads as the parent of these groups.
private struct ProviderHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary.opacity(0.75))
            Spacer()
        }
        .padding(.leading, 10)
        .padding(.top, 2)
    }
}

/// One Supabase project: a steady dot (paused projects dim and say so — Supabase stops
/// serving a paused project until it's restored, which is the state worth noticing), the
/// name, its live round-trip, and its region. Expands like the Oracle rows.
private struct SupabaseRow: View {
    let project: SupabaseProject
    let health: HealthStatus?
    let isExpanded: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            CompactRowShell(
                title: project.name,
                titleColor: project.isHealthy ? Theme.textPrimary : Theme.textSecondary,
                dimmed: project.isPaused,
                help: project.isPaused
                    ? "\(project.name) is paused — expand to restore it"
                    : (isExpanded ? "Collapse" : "Show details"),
                onTap: onTap
            ) {
                InfraDot(color: dotColor)
            } trailing: { _ in
                if project.isPaused {
                    Text("paused")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.contextWarn)
                        .fixedSize()
                } else if !project.isHealthy {
                    Text(project.status.lowercased().replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                } else if let health, health != .unknown {
                    Text(health.shortLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(health.isUp ? Theme.textTertiary : Theme.statusError)
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            if isExpanded {
                SupabaseDetailPanel(project: project, health: health)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: isExpanded)
    }

    /// A project that reports healthy but isn't answering gets the error colour — the
    /// control plane's opinion loses to an actual probe.
    private var dotColor: Color {
        if let health, health != .unknown, !health.isUp { return Theme.statusError }
        return project.isHealthy ? Theme.textSecondary : Theme.textTertiary
    }
}

/// The Supabase drill-in: how long it has existed, what it runs, and whether it is
/// actually answering right now.
private struct SupabaseDetailPanel: View {
    let project: SupabaseProject
    let health: HealthStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(detailLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Text(healthLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(healthColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                QuietLink("dashboard", size: 10) {
                    let encoded = project.id.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed
                    ) ?? project.id
                    if let url = URL(string: "https://supabase.com/dashboard/project/\(encoded)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// "up 5w · pg17 · ca-central-1" — each part dropped when unknown.
    private var detailLine: String {
        var parts: [String] = []
        if let created = project.createdAt {
            parts.append("up \(AgeFormat.longSpan(from: created))")
        }
        if let version = project.postgresVersion { parts.append("pg\(version)") }
        if !project.region.isEmpty { parts.append(project.region) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// The probe's verdict in words — the row's number without the guesswork.
    private var healthLine: String {
        guard !project.isPaused else { return "paused — restore it from the dashboard" }
        // Only a serving project is probed; anything transitional would say "checking…"
        // forever, because no check is coming.
        guard project.isHealthy else {
            return "\(project.status.lowercased().replacingOccurrences(of: "_", with: " ")) — not serving"
        }
        switch health {
        case .ok(let code, let latency)?:
            return "answering \(code) in \(Int((latency * 1000).rounded()))ms"
        case .degraded(let code, _)?:
            return "answering \(code) — server error"
        case .down(let reason)?:
            return "not responding · \(reason.label)"
        case .unknown?, nil:
            return "checking…"
        }
    }

    private var healthColor: Color {
        switch health {
        case .degraded?, .down?: return Theme.statusError
        default: return Theme.textTertiary
        }
    }
}

/// A service named in endpoints.json — something linkC can't discover on its own, like a
/// web app behind a domain. The row IS its health: there's nothing else to say about it.
private struct WatchedServiceRow: View {
    let endpoint: WatchedEndpoint
    let health: HealthStatus?

    var body: some View {
        CompactRowShell(
            title: endpoint.label,
            titleColor: isDown ? Theme.textSecondary : Theme.textPrimary,
            help: helpText,
            onTap: { NSWorkspace.shared.open(endpoint.url) }
        ) {
            InfraDot(color: isDown ? Theme.statusError : Theme.textSecondary)
        } trailing: { _ in
            if let health, health != .unknown {
                Text(health.shortLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isDown ? Theme.statusError : Theme.textTertiary)
                    .fixedSize()
            }
        }
    }

    private var isDown: Bool {
        guard let health, health != .unknown else { return false }
        return !health.isUp
    }

    /// The row has space for the short label ("tls", "dns"); the whole sentence lives here,
    /// so a failure is never just the word "down" with nowhere to go.
    private var helpText: String {
        guard case .down(let reason)? = health else { return endpoint.url.absoluteString }
        return "\(endpoint.url.absoluteString)\n\(reason.detail)"
    }
}

/// One cloud box as a quiet row: a steady dot (running reads like a dev terminal, not a
/// claude state — infra never pulses), the instance name, its state when it isn't
/// running, and the region.
private struct CloudRow: View {
    let instance: OracleInstance
    /// The DEFAULT profile's region — one per config, so it rides on the service.
    let region: String?
    let detail: OracleDetail?
    let isExpanded: Bool
    let onTap: () -> Void
    let onRefresh: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            CompactRowShell(
                title: instance.name,
                titleColor: instance.isRunning ? Theme.textPrimary : Theme.textSecondary,
                help: isExpanded ? "Collapse" : "Show details",
                onTap: onTap
            ) {
                InfraDot(color: instance.isRunning ? Theme.textSecondary : Theme.textTertiary)
            } trailing: { _ in
                if !instance.isRunning {
                    Text(instance.state.lowercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                if let region {
                    Text(region)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            if isExpanded {
                CloudDetailPanel(instance: instance, detail: detail, onRefresh: onRefresh)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: isExpanded)
    }
}

/// The expanded drill-in: is it healthy, and is it still mine? Figures wrap onto lines
/// that fit a 260pt rail (the first cut wrapped "cpu" into c/p/u), and every label is
/// fixed-size so a starved row truncates values, never letter-stacks a word.
private struct CloudDetailPanel: View {
    let instance: OracleInstance
    let detail: OracleDetail?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Health: uptime and the three utilization figures worth watching.
            Text(healthLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            // Security: who has been touching the account.
            HStack(spacing: 4) {
                Text(auditLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(detail?.audit?.hasUnknownPrincipal == true
                        ? Theme.contextWarn : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 10) {
                Text(detail?.publicIP ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                QuietLink("refresh", size: 10, action: onRefresh)
                QuietLink("console", size: 10) {
                    NSWorkspace.shared.open(URL(string: "https://cloud.oracle.com/compute/instances")!)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// "up 17d · cpu 2% · mem 11% · load 0.3" — each part dropped when unknown rather
    /// than shown as a confident zero.
    private var healthLine: String {
        var parts: [String] = []
        // Uptime only for a running box — createdAt is creation, not boot, so a stopped
        // instance would otherwise claim to be "up".
        if instance.isRunning, let created = instance.createdAt {
            parts.append("up \(AgeFormat.longSpan(from: created))")
        }
        if let cpu = detail?.cpuPercent { parts.append("cpu \(Int(cpu.rounded()))%") }
        if let memory = detail?.memoryPercent { parts.append("mem \(Int(memory.rounded()))%") }
        if let load = detail?.loadAverage {
            parts.append("load \(String(format: "%.1f", load))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// "12 events · you" / "12 events · you, someone-else" — the unfamiliar name is the
    /// signal, and it golds the line.
    private var auditLine: String {
        guard let audit = detail?.audit else { return "—" }
        let noun = audit.eventCount == 1 ? "event" : "events"
        guard !audit.humanPrincipals.isEmpty else { return "\(audit.eventCount) \(noun) · system only" }
        return "\(audit.eventCount) \(noun) · \(audit.humanPrincipals.joined(separator: ", "))"
    }
}
