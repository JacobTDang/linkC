import SwiftUI
import AppKit
import LinkCKit

/// The scrolling session/terminal/earlier column — the whole of home's list, reusable as
/// the sidebar beside an open terminal. In sidebar mode `selectedId` highlights the open
/// item, `horizontalPadding` lets the caller own the gutters, and `compact` swaps the full
/// cards for one-line rail rows: at 260pt the cards' paths, previews, and agent lanes read
/// as clutter, and a starved Restore label wraps letter-by-letter.
struct SessionListColumn: View {
    let model: AppModel
    var selectedId: String? = nil
    var horizontalPadding: CGFloat = 12
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One row of the sectioned overview: a section header or a live session card. Cards keep a
    /// stable id (`session.id`) so a state change reorders the flat list and SwiftUI *moves* the
    /// card to its new section rather than recreating it — that move is what the spring animates.
    private enum Row: Identifiable {
        case header(String)
        case card(Session)

        var id: String {
            switch self {
            case .header(let title): return "header-\(title)"
            case .card(let session): return session.id
            }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                // Live cards refresh their terminal previews about once a second — and only while
                // this column is on screen, since it exists only then. Restorable cards have no
                // live output, so they sit outside the timeline.
                if !model.sessions.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        liveSections
                    }
                }
                // Dev terminals: same 1s preview cadence as sessions, quieter presence.
                if !model.shellRows.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        TerminalsSection(model: model, selectedId: selectedId, compact: compact)
                    }
                }
                // The sidebar is for what's live: running servers ride here, and restorable
                // history stays on home — restoring is a home decision, not a mid-session one.
                if compact {
                    ServersSection(model: model)
                } else if !model.restorables.isEmpty {
                    EarlierSection(model: model)
                }
            }
            .readingColumn()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
        }
    }

    /// The live sessions as a priority queue: NEEDS YOU → WORKING → IDLE, each a stable row in one
    /// flat list so cards glide between sections on a state change. Reduce Motion drops the spring.
    @MainActor @ViewBuilder private var liveSections: some View {
        let rows = self.rows
        VStack(spacing: 6) {
            ForEach(rows) { row in
                switch row {
                case .header(let title):
                    SectionHeader(title: title)
                        .padding(.top, 6)
                        .transition(.opacity)
                case .card(let session):
                    Group {
                        if compact {
                            CompactSessionRow(
                                session: session,
                                runningAgents: model.visibleAgents(session.id).count(where: \.isRunning),
                                activity: model.currentActivity(session),
                                isSelected: session.id == selectedId,
                                onOpen: { model.focus(session.id) },
                                onClose: { model.stop(session.id) }
                            )
                        } else {
                            HomeCard(
                                session: session,
                                preview: model.recentOutput(session.id, lines: 3),
                                contextFill: model.contextFill(session.id),
                                agents: model.visibleAgents(session.id),
                                activity: model.currentActivity(session),
                                isSelected: session.id == selectedId,
                                onOpen: { model.focus(session.id) },
                                onClose: { model.stop(session.id) }
                            )
                        }
                    }
                    // Cards materialize: a soft settle-in rather than a pop. Reduce Motion
                    // keeps only the fade.
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: rows.map(\.id))
    }

    /// Group live sessions by urgency bucket, in priority order, preserving each session's relative
    /// order within its bucket. Empty buckets are dropped; headers are shown only when more than one
    /// bucket is present (a lone group needs no label).
    @MainActor private var rows: [Row] {
        let sessions = model.sessions
        let groups: [(String, [Session])] = [
            ("NEEDS YOU", sessions.filter { $0.state.bucket == .needsYou }),
            ("WORKING", sessions.filter { $0.state.bucket == .active }),
            ("IDLE", sessions.filter { $0.state.bucket == .idle }),
        ].filter { !$0.1.isEmpty }

        let showHeaders = groups.count > 1
        return groups.flatMap { title, group -> [Row] in
            (showHeaders ? [Row.header(title)] : []) + group.map(Row.card)
        }
    }
}

// MARK: - Terminals (dev shells)

/// The dev-terminal section — plain shells beside the claude sessions, deliberately
/// quieter (no urgency states, no pulse).
private struct TerminalsSection: View {
    let model: AppModel
    var selectedId: String? = nil
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            SectionHeader(title: "TERMINALS")
                .padding(.top, 6)
            ForEach(model.shellRows) { row in
                Group {
                    if compact {
                        CompactTerminalRow(
                            row: row,
                            isSelected: row.id == selectedId,
                            onOpen: { model.focus(row.id) },
                            onStop: { model.stopShell(row.id) },
                            onRelaunch: { model.relaunchShell(row) },
                            onDismiss: { model.dismissShell(row.id) }
                        )
                    } else {
                        TerminalCard(
                            row: row,
                            preview: model.recentOutput(row.id, lines: 3),
                            isSelected: row.id == selectedId,
                            onOpen: { model.focus(row.id) },
                            onStop: { model.stopShell(row.id) },
                            onRelaunch: { model.relaunchShell(row) },
                            onDismiss: { model.dismissShell(row.id) }
                        )
                    }
                }
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: model.shellRows.map(\.id))
    }
}

// MARK: - Earlier (restorable sessions)

/// Previous sessions from an earlier run, shown below the live cards: a quiet section header —
/// with an inline "Restore all" only when there are 2+ to restore — then one dim row per
/// restorable session.
private struct EarlierSection: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("EARLIER")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                // "Restore all" earns its place only when there is more than one thing to
                // restore; inline with the label so it never stacks over the rows' own
                // Restore buttons.
                if model.restorables.count > 1 {
                    Text("·")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Button(action: { model.restoreAll() }) {
                        Text("Restore all")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Restore every previous session")
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            ForEach(model.restorables) { session in
                RestorableRow(
                    session: session,
                    onRestore: { model.restore(session) },
                    onDismiss: { model.dismiss(session) }
                )
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        // Restored/dismissed rows leave with the section spring so the rest glide up.
        .animation(reduceMotion ? nil : Theme.sectionSpring, value: model.restorables.map(\.id))
    }
}

/// One previous session as a quiet row — transparent until hovered, when a soft wash and its
/// dismiss x appear. History shouldn't compete with live cards: no fill, no preview, just an
/// ended-grey dot, the title and folder, when it ended, and a plain Restore action.
private struct RestorableRow: View {
    let session: RestorableSession
    let onRestore: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: .ended)
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let endedText = session.endedLabel(now: Date()) {
                Text(endedText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }

            Spacer(minLength: 8)

            Button(action: onRestore) {
                Text("Restore")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()   // starved rows must truncate the title, never wrap the action
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Resume this session")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.hover : Color.clear)
        )
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A single session card: a soft fill (a faint coral wash when it needs you), a status · title ·
/// path header line, and a dim monospaced preview of the last few terminal rows aligned under the
/// title. The state is the dot; words appear only when the session needs you. The whole card is
/// the tap target. `isSelected` (the sidebar's open item) brightens the plane and hangs an
/// accent hairline off the leading edge.
private struct HomeCard: View {
    let session: Session
    let preview: String
    /// 0…1 context-window fill for the hairline along the bottom edge; nil hides it.
    let contextFill: Double?
    /// Subagents worth showing: running ones plus the recently finished.
    let agents: [AgentRun]
    /// The current command/file/subagent while working — fills the header's middle.
    var activity: String? = nil
    var isSelected: Bool = false
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(state: session.state)
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let activity {
                    Text(activity)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                // State text only when there's something to act on — the dot carries the rest.
                if session.state.bucket == .needsYou {
                    // Time-in-state: a 10-second wait and a 20-minute wait are different
                    // situations — say which this is.
                    Text("\(statusLabel(session.state)) · \(AgeFormat.compact(from: session.stateChangedAt))")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.statusColor(session.state))
                        .fixedSize()
                }
                if agents.contains(where: \.isRunning) {
                    AgentChip(count: agents.count { $0.isRunning })
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Stop session")
            }
            PreviewText(text: preview)
            // The agent lane: the card grows quietly while the session fans out.
            if !agents.isEmpty {
                VStack(spacing: 2) {
                    ForEach(agents) { AgentLine(agent: $0) }
                }
                .padding(.top, 4)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Context fill as a 2pt hairline flush to the bottom edge — quiet white until the
        // conversation nears auto-compact, then the warning gold. Clipped to the card shape
        // before the plane goes on, so the shadow isn't clipped with it.
        .overlay(alignment: .bottomLeading) {
            if let contextFill {
                GeometryReader { geo in
                    Rectangle()
                        .fill(contextFill > 0.75 ? Theme.contextWarn : Color.white.opacity(0.25))
                        .frame(width: geo.size.width * contextFill, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .planeCard(needsYou: session.state.bucket == .needsYou, hovering: hovering || isSelected)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: 2)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .animation(Theme.hoverEase, value: isSelected)
        .help("Open \(session.title)")
    }
}

// MARK: - Compact (sidebar) rows

/// Sidebar-density session row: the dot, the title, and only what demands attention — a
/// needs-you age and a running-agent chip. Paths, previews, and agent lanes stay on home;
/// at rail width they read as clutter, and the strip above the terminal already shows agents.
private struct CompactSessionRow: View {
    let session: Session
    let runningAgents: Int
    /// The current command/file/subagent while working — fills the space after the title.
    let activity: String?
    let isSelected: Bool
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: session.state)
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)   // the title never yields to the activity text
            if let activity {
                Text(activity)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if session.state.bucket == .needsYou {
                // The age alone — the pulsing dot already says "needs you"; words don't fit here.
                Text(AgeFormat.compact(from: session.stateChangedAt))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.statusColor(session.state))
                    .fixedSize()
            }
            if runningAgents > 0 {
                AgentChip(count: runningAgents)
            }
            Button(action: onClose) {
                CompactRowGlyph()
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Stop session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .planeCard(needsYou: session.state.bucket == .needsYou, hovering: hovering || isSelected)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .padding(.leading, 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .animation(Theme.hoverEase, value: isSelected)
        .help(isSelected ? "\(session.title) — current" : "Switch to \(session.title)")
    }
}

/// Sidebar-density dev-terminal row: the quiet steady dot and the title. Running rows get a
/// hover stop; exited rows dim, keep Relaunch, and reveal dismiss on hover.
private struct CompactTerminalRow: View {
    let row: ShellRow
    let isSelected: Bool
    let onOpen: () -> Void
    let onStop: () -> Void
    let onRelaunch: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    private var isRunning: Bool { row.state == .running }

    private var dotColor: Color {
        switch row.state {
        case .running: return Theme.textSecondary
        case .exited(let code): return code == 0 ? Theme.textTertiary : Theme.statusError
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .frame(width: 18, height: 18)  // StatusDot's box, minus its glow
            Text(row.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isRunning ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isRunning {
                Button(action: onStop) {
                    CompactRowGlyph()
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Stop terminal")
            } else {
                Button(action: onRelaunch) {
                    Text("Relaunch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open a fresh shell in this folder")
                Button(action: onDismiss) {
                    CompactRowGlyph()
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .planeCard(hovering: (hovering && isRunning) || isSelected)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .padding(.leading, 1)
            }
        }
        .opacity(isRunning ? 1 : 0.75)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .animation(Theme.hoverEase, value: isSelected)
        .help(isRunning ? "Open \(row.title)" : "View \(row.title)'s last output")
    }
}

// MARK: - Servers (sidebar)

/// The sidebar's running-servers section: compose projects with live containers, then
/// standalone running containers, each ranked hottest-first by live CPU — the power proxy
/// (per-container energy doesn't exist on macOS; every container shares one VM). Read-only
/// pointers into the Tool Servers screen; hidden entirely when nothing runs.
private struct ServersSection: View {
    let model: AppModel

    var body: some View {
        let projects = model.runningProjectsByPower
        let standalone = model.runningStandaloneByPower
        if !projects.isEmpty || !standalone.isEmpty {
            VStack(spacing: 6) {
                SectionHeader(title: "SERVERS")
                    .padding(.top, 6)
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

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.textSecondary)
                .frame(width: 8, height: 8)
                .frame(width: 18, height: 18)  // StatusDot's box, minus its glow
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let count, count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if cpuPercent >= 1 {
                Text("\(Int(cpuPercent.rounded()))%")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(warn ? Theme.contextWarn : Theme.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .planeCard(hovering: hovering)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help("Open Tool Servers")
    }
}

/// The compact rows' shared hover ✕.
private struct CompactRowGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}

/// Shared status copy for a card's needs-you label.
private func statusLabel(_ state: SessionState) -> String {
    switch state {
    case .starting: return "starting"
    case .ready: return "ready"
    case .working: return "working"
    case .waitingPermission: return "needs permission"
    case .waitingIdle: return "waiting for input"
    case .finished: return "finished"
    case .error: return "error"
    case .ended: return "ended"
    }
}
