import SwiftUI
import AppKit
import LinkCKit

// MARK: - Panel

/// The panel content: a slim chrome strip, then the home overview or the selected session's
/// terminal as the hero. Draws no opaque background of its own — the frosted `NSVisualEffectView`
/// behind it (set up in `StatusPanelController`) shows through as glass, and nothing inside is
/// outlined: content floats as soft fills of the same material.
struct PanelView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let error = model.setupError {
                SetupErrorView(message: error)
            } else {
                VStack(spacing: 0) {
                    // The + hides while the empty state shows — the empty state is the launcher
                    // then, and two launch affordances never share the screen.
                    PanelHeader(
                        model: model,
                        showsLauncher: model.selectedId != nil
                            || model.activeScreen != nil
                            || !model.sessions.isEmpty
                            || !model.restorables.isEmpty
                            || !model.shellRows.isEmpty
                    )
                    // Pane swap: terminal > dock screen > empty > home. The terminal is a live
                    // NSView, so its removal is a plain fade (no reflow); pure-translate slides
                    // bring the others in. Reduce Motion collapses everything to a crossfade.
                    // The dock rides every pane but the terminal as a trailing overlay — content
                    // reserves its inset so nothing hides under the glass.
                    GeometryReader { geo in
                        let showsDock = model.selectedId == nil
                            && geo.size.width >= Theme.dockBreakpoint
                        ZStack {
                            if model.selectedId != nil {
                                TerminalHero(model: model)
                                    .transition(reduceMotion
                                        ? .opacity
                                        : .asymmetric(
                                            insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                            } else if let screen = model.activeScreen {
                                ScreenHost(model: model, screen: screen)
                                    .transition(reduceMotion
                                        ? .opacity
                                        : .asymmetric(
                                            insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                            } else if model.isEmptyOverview {
                                EmptyStateView(model: model)
                                    .transition(.opacity)
                            } else {
                                HomeView(model: model)
                                    .transition(reduceMotion
                                        ? .opacity
                                        : .asymmetric(
                                            insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .opacity))
                            }
                        }
                        .padding(.trailing, showsDock ? Theme.dockInset : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .trailing) {
                            if showsDock {
                                Dock(model: model, selected: model.activeScreen)
                                    .padding(.trailing, 10)
                                    .transition(.opacity)
                            }
                        }
                        .animation(Theme.viewSwap, value: Pane(model))
                    }
                    if let error = model.lastError {
                        ErrorBar(message: error)
                            .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Theme.viewSwap, value: model.lastError)
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        // A faint radial vignette grounds the sheet's edges — depth, not a border.
        .overlay {
            GeometryReader { geo in
                let reach = max(geo.size.width, geo.size.height)
                Rectangle()
                    .fill(RadialGradient(
                        colors: [.clear, Theme.vignette],
                        center: UnitPoint(x: 0.5, y: 0.4),
                        startRadius: reach * 0.45,
                        endRadius: reach))
            }
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        // Stock controls (switches, pickers, spinners) inherit the system's blue accent
        // otherwise — the panel is coral everywhere, including its toggles.
        .tint(Theme.accent)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }
}

/// One Equatable discriminator for the pane-swap animation — the ZStack has four branches now,
/// so a single boolean can't drive `.animation(_:value:)` anymore.
private enum Pane: Equatable {
    case terminal, screen(PanelScreen), empty, home

    @MainActor init(_ model: AppModel) {
        if model.selectedId != nil { self = .terminal }
        else if let screen = model.activeScreen { self = .screen(screen) }
        else if model.isEmptyOverview { self = .empty }
        else { self = .home }
    }
}

// MARK: - Screens

/// Hosts a dock screen — the dock itself rides above as PanelView's trailing overlay, so the
/// user can hop between screens without going home first.
private struct ScreenHost: View {
    let model: AppModel
    let screen: PanelScreen

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .mcpServers: MCPServersScreen(model: model)
        case .skills: SkillsScreen(model: model)
        case .terminals: TerminalsScreen(model: model)
        case .toolServers: ToolServersScreen(model: model)
        case .settings: SettingsScreen(model: model)
        }
    }
}

// MARK: - Header

/// The chrome strip: no title, no divider — just what's true right now. Dot-count badges on the
/// left (running teal, waiting coral, hidden at zero), bare glyph actions on the right, and the
/// back chevron only while a terminal is open.
private struct PanelHeader: View {
    let model: AppModel
    let showsLauncher: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.selectedId != nil || model.activeScreen != nil {
                ChromeButton(systemName: "chevron.left", help: "Back to overview") { model.goHome() }
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
            CountBadge(color: Theme.statusRunning, count: model.activeCount)
            CountBadge(color: Theme.statusNeedsYou, count: model.needsYouCount)
            Spacer(minLength: 8)
            // The open session's spend, roughly centered in the chrome — tokens always,
            // dollars only when every model in the session is priced.
            if let label = model.selectedUsageLabel {
                Text(label)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
                Spacer(minLength: 8)
            }
            if showsLauncher {
                LauncherMenu(model: model)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        // Badges and the back chevron come and go with the same soft scale-fade.
        .animation(Theme.hoverEase, value: [model.activeCount, model.needsYouCount])
        .animation(Theme.viewSwap, value: model.selectedId != nil)
        .animation(Theme.viewSwap, value: model.activeScreen)
        .animation(Theme.viewSwap, value: showsLauncher)
    }
}

/// A tiny dot-and-count pair. Rendered only when the count is non-zero — the header never
/// states an absence.
private struct CountBadge: View {
    let color: Color
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if count > 0 {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        }
    }
}

/// A bare chrome glyph button — no box, no border. Hover raises it with a soft circular wash.
struct ChromeButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChromeGlyph(systemName: systemName, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Shared rendering for chrome glyphs — used by plain buttons and the launcher `Menu` label,
/// which manages its own hover state.
struct ChromeGlyph: View {
    let systemName: String
    let hovering: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(hovering ? Theme.hover : Color.clear))
            .contentShape(Circle())
            .animation(Theme.hoverEase, value: hovering)
    }
}

/// The `+` launcher — new / continue / resume are the existing `AppModel` actions.
private struct LauncherMenu: View {
    let model: AppModel

    @State private var hovering = false

    var body: some View {
        Menu {
            Button("New session…") { model.newSession(mode: .new) }
            Button("Continue last…") { model.newSession(mode: .continueLast) }
            Button("Resume…") { model.newSession(mode: .resume) }
            Button("New terminal…") { model.newShellTerminal() }
            Divider()
            Button("Quit linkC") { NSApplication.shared.terminate(nil) }
        } label: {
            ChromeGlyph(systemName: "plus", hovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("New session")
    }
}

// MARK: - Home overview

/// The overview shown when no session is selected: every session as a compact card with a live
/// preview of its recent terminal output. `TimelineView(.periodic)` refreshes the previews about
/// once a second — and only while home is on screen, since this view exists only then, so no
/// manual timer is needed. Tapping a card opens that session's full terminal.
private struct HomeView: View {
    let model: AppModel

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
        VStack(spacing: 0) {
            sessionList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The one place plan usage appears: a quiet footer line pinned under the list.
            if let label = model.windowUsageLabel, model.preferences.showsUsageFooter {
                HStack {
                    Text(label)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                // Live cards refresh their terminal previews about once a second — and only while
                // home is on screen, since this view exists only then. Restorable cards have no
                // live output, so they sit outside the timeline.
                if !model.sessions.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        liveSections
                    }
                }
                // Dev terminals: same 1s preview cadence as sessions, quieter presence.
                if !model.shellRows.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        TerminalsSection(model: model)
                    }
                }
                if !model.restorables.isEmpty {
                    EarlierSection(model: model)
                }
            }
            .readingColumn()
            .padding(.horizontal, 12)
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
                    HomeCard(
                        session: session,
                        preview: model.recentOutput(session.id, lines: 3),
                        contextFill: model.contextFill(session.id),
                        agents: model.visibleAgents(session.id),
                        onOpen: { model.focus(session.id) },
                        onClose: { model.stop(session.id) }
                    )
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

/// A quiet section label — the priority-queue headers share the EARLIER header's styling.
struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Terminals (dev shells)

/// The home overview's dev-terminal section — plain shells beside the claude sessions,
/// deliberately quieter (no urgency states, no pulse).
struct TerminalsSection: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            SectionHeader(title: "TERMINALS")
                .padding(.top, 6)
            ForEach(model.shellRows) { row in
                TerminalCard(
                    row: row,
                    preview: model.recentOutput(row.id, lines: 3),
                    onOpen: { model.focus(row.id) },
                    onStop: { model.stopShell(row.id) },
                    onRelaunch: { model.relaunchShell(row) },
                    onDismiss: { model.dismissShell(row.id) }
                )
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
/// the tap target.
private struct HomeCard: View {
    let session: Session
    let preview: String
    /// 0…1 context-window fill for the hairline along the bottom edge; nil hides it.
    let contextFill: Double?
    /// Subagents worth showing: running ones plus the recently finished.
    let agents: [AgentRun]
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
        .planeCard(needsYou: session.state.bucket == .needsYou, hovering: hovering)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help("Open \(session.title)")
    }
}

/// The card's monospaced output preview, sitting directly on the card fill and indented to align
/// with the title (past the status dot's box). Falls back to a dim placeholder when there's
/// nothing to show yet, so a fresh card never reads as blank or broken.
struct PreviewText: View {
    let text: String

    var body: some View {
        Group {
            if text.isEmpty {
                Text("starting…").foregroundStyle(Theme.textTertiary)
            } else {
                Text(text).foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(3)
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        // A fixed 3-line well: the height is reserved (blank lines allowed) so a card never
        // resizes as its output changes.
        .frame(
            maxWidth: .infinity,
            minHeight: Theme.previewHeight, maxHeight: Theme.previewHeight,
            alignment: .topLeading
        )
        .padding(.leading, 26)   // dot box (18) + header spacing (8): preview aligns under the title
    }
}

// MARK: - Terminal (hero)

private struct TerminalHero: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An agent opened for reading — replaces the terminal until dismissed.
    @State private var readerAgent: AgentRun?

    var body: some View {
        ZStack {
            if let readerAgent {
                AgentReaderView(agent: currentAgent(readerAgent)) { self.readerAgent = nil }
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    // Live subagents ride above the terminal; TimelineView keeps their
                    // ages/spinners honest while the strip is visible.
                    if let id = model.selectedId, !model.visibleAgents(id).isEmpty {
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            AgentStrip(agents: model.visibleAgents(id)) { readerAgent = $0 }
                        }
                        .transition(.opacity)
                    }
                    ZStack {
                        TerminalContainer(session: model.selectedTerminal)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                        if model.selectedTerminal == nil {
                            Text("Select a session")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.viewSwap, value: readerAgent?.id)
        .onChange(of: model.selectedId, initial: true) { _, _ in
            readerAgent = nil
            styleTerminal(model.selectedTerminal)
        }
    }

    /// Re-resolve the opened agent so a completion arriving mid-read fills the body in.
    private func currentAgent(_ agent: AgentRun) -> AgentRun {
        guard let id = model.selectedId else { return agent }
        return model.visibleAgents(id).first { $0.id == agent.id } ?? agent
    }

    /// Restyle the live terminal to the tokens from the panel side (the Terminal module is left
    /// untouched): SF Mono at 12.5 and a genuinely translucent background, so the glass reads
    /// through the terminal itself instead of framing an opaque slab. SwiftTerm keeps the
    /// NSColor's alpha for every default-background cell fill; the one opaque remnant is the
    /// view's CALayer background, which `setupOptions()` re-stamps on font changes — so the
    /// font must be set first and the layer cleared last.
    private func styleTerminal(_ session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.30)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - Empty state

/// The launcher: while nothing exists the panel's one entry point is here, not the chrome —
/// the header + is hidden. A halo hero with the primary New session action, quiet
/// Continue/Resume beneath, recent folders as one-tap starters, and (since the + menu is
/// gone) a faint quit link in the corner.
private struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        // Centered while it fits; a short panel scrolls rather than clipping the chips.
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                hero
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            QuietLink("quit linkC", size: 10) { NSApplication.shared.terminate(nil) }
                .padding(12)
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            HeroHalo()
            Text("Ready when you are")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 12)
            Text("Claude Code sessions run right here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 3)
            Button("New session") { model.newSession(mode: .new) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 18)
            HStack(spacing: 6) {
                QuietLink("Continue last") { model.newSession(mode: .continueLast) }
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                QuietLink("Resume…") { model.newSession(mode: .resume) }
            }
            .padding(.top, 10)
            if !model.recentFolders.isEmpty {
                jumpBackIn.padding(.top, 26)
            }
        }
    }

    /// The void gains function: the last few launch folders as one-tap session starters —
    /// no folder picker in the way.
    private var jumpBackIn: some View {
        VStack(spacing: 8) {
            Text("JUMP BACK IN")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                ForEach(model.recentFolders, id: \.self) { path in
                    FolderChip(path: path) { model.startSession(in: path) }
                }
            }
        }
    }
}

/// The empty state's signature: a breathing coral core inside a soft halo — the dot grown
/// into a hero. Reduce Motion holds the core steady.
private struct HeroHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Theme.accent.opacity(0.28), .clear],
                    center: .center, startRadius: 2, endRadius: 37))
            Circle()
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
                .frame(width: 46, height: 46)
            Circle()
                .fill(Theme.accent)
                .frame(width: 12, height: 12)
                .shadow(color: Theme.accent.opacity(0.55), radius: 9)
                .scaleEffect(reduceMotion ? 1 : (up ? 1.06 : 0.92))
        }
        .frame(width: 74, height: 74)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { up = true }
        }
    }
}

/// One recent folder as a quiet capsule chip: the folder's name with its tilde-abbreviated
/// parent, warming on hover. Tapping starts a new session there directly.
private struct FolderChip: View {
    let path: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString)
            .abbreviatingWithTildeInPath
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                Text(parent)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(hovering ? Theme.hover : Color.white.opacity(0.055))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
        .help("Start a new session in \(name)")
    }
}

/// A small muted text action — tertiary grey that warms to secondary on hover.
struct QuietLink: View {
    let title: String
    let size: CGFloat
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, size: CGFloat = 11, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size))
                .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Setup error

private struct SetupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.statusError)
            Text("Setup needed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Quit linkC") { NSApplication.shared.terminate(nil) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Error bar

/// A one-off action failure, surfaced as a soft red-washed strip floating above the bottom edge —
/// loud enough to read, quiet enough to leave the panel intact.
struct ErrorBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.statusError)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(Theme.errorWash)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - Button style

/// The one prominent action: a coral gradient capsule with an inner top highlight and a
/// soft glow — real depth, matching the dock's selection pill.
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.878, green: 0.502, blue: 0.373),
                            Color(red: 0.769, green: 0.392, blue: 0.275),
                        ],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), .clear],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 1))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 4)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Shared copy

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
