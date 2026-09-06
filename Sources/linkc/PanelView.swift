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
                            || !model.restorableShells.isEmpty
                    )
                    // Pane swap: dock screen > terminal > empty > home. Screens LAYER over an
                    // open terminal instead of evicting it — closing the screen (back) lands
                    // exactly where the user was; focusing a session still clears the screen,
                    // so a session needing attention keeps outranking a static screen. The
                    // terminal is a live NSView, so its removal is a plain fade (no reflow);
                    // pure-translate slides bring the others in. Reduce Motion collapses
                    // everything to a crossfade. The dock rides every pane but the terminal
                    // as a trailing overlay — content reserves its inset so nothing hides
                    // under the glass.
                    GeometryReader { geo in
                        let showsDock = (model.selectedId == nil || model.activeScreen != nil)
                            && geo.size.width >= Theme.dockBreakpoint
                        ZStack {
                            if let screen = model.activeScreen {
                                ScreenHost(model: model, screen: screen)
                                    .transition(reduceMotion
                                        ? .opacity
                                        : .asymmetric(
                                            insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                            } else if model.selectedId != nil {
                                TerminalHero(model: model)
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
        if let screen = model.activeScreen { self = .screen(screen) }
        else if model.selectedId != nil { self = .terminal }
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
                // Back peels one layer: a screen closes onto whatever was under it (the
                // open terminal, or home); the terminal closes onto home.
                ChromeButton(systemName: "chevron.left", help: "Back") { model.goBack() }
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

/// The `+` launcher — 1-click launch for all supported autonomous agents and terminals.
private struct LauncherMenu: View {
    let model: AppModel

    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Autonomous Agent") {
                Button("New Claude session…") { model.newSession(agent: .claude, mode: .new) }
                Button("New Antigravity (agy) session…") { model.newSession(agent: .agy, mode: .new) }
                Button("New Cursor Agent session…") { model.newSession(agent: .cursor, mode: .new) }
                Button("New Codex session…") { model.newSession(agent: .codex, mode: .new) }
            }
            Section("Terminal") {
                Button("New terminal (zsh)…") { model.newShellTerminal() }
            }
            Divider()
            Menu("Continue last…") {
                Button("Claude") { model.newSession(agent: .claude, mode: .continueLast) }
                Button("Antigravity (agy)") { model.newSession(agent: .agy, mode: .continueLast) }
                Button("Cursor Agent") { model.newSession(agent: .cursor, mode: .continueLast) }
                Button("Codex") { model.newSession(agent: .codex, mode: .continueLast) }
            }
            Menu("Resume…") {
                Button("Claude") { model.newSession(agent: .claude, mode: .resume) }
                Button("Antigravity (agy)") { model.newSession(agent: .agy, mode: .resume) }
                Button("Cursor Agent") { model.newSession(agent: .cursor, mode: .resume) }
                Button("Codex") { model.newSession(agent: .codex, mode: .resume) }
            }
            Divider()
            Button("Quit linkC") { NSApplication.shared.terminate(nil) }
        } label: {
            ChromeGlyph(systemName: "plus", hovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("New session or terminal")
    }
}

// MARK: - Home overview

/// The overview shown when no session is selected: the shared session-list column with the
/// plan-usage footer pinned beneath it. Tapping a card opens that session's full terminal.
private struct HomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SessionListColumn(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A fresh build waiting in dist — one strip, home only.
            if let update = model.updateAvailable {
                UpdateBar(update: update) { model.installUpdate() }
                    .transition(.opacity)
            }
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

/// The open terminal, split beside the session list when the pane is wide enough. Narrow
/// panes keep the original full-bleed terminal with the mini-tab strip; the split's sidebar
/// replaces the strip entirely. The agent reader swaps only the terminal side in the split
/// (the whole pane when narrow).
private struct TerminalHero: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.setWindowDraggable) private var setWindowDraggable
    /// An agent opened for reading — replaces the terminal until dismissed.
    @State private var readerAgent: AgentRun?
    /// Whether the pointer is hovering over the active terminal area.
    @State private var isHoveringTerminal = false

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= Theme.splitBreakpoint
            HStack(alignment: .top, spacing: 12) {
                if split {
                    SessionListColumn(model: model, selectedId: model.selectedId, horizontalPadding: 0, compact: true)
                        .frame(width: Theme.sidebarWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                rightPane(split: split)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .onChange(of: model.selectedId, initial: true) { _, _ in
            readerAgent = nil
            styleTerminal(model.selectedTerminal)
        }
    }

    /// The terminal column (or the agent reader in its place). In the split the sidebar is
    /// the switcher, so the mini-tab strip renders only when narrow.
    @ViewBuilder private func rightPane(split: Bool) -> some View {
        ZStack {
            if let readerAgent {
                AgentReaderView(agent: currentAgent(readerAgent)) { self.readerAgent = nil }
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    // Sibling sessions as mini-tabs — switch without going home.
                    if !split, model.showsSessionStrip {
                        SessionStrip(sessions: model.sessions, selectedId: model.selectedId) {
                            model.focus($0)
                        }
                        .transition(.opacity)
                    }
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
                            .onHover { hovering in
                                let active = hovering && model.selectedTerminal != nil
                                if active != isHoveringTerminal {
                                    isHoveringTerminal = active
                                    setWindowDraggable(!active)
                                }
                            }
                            .onDisappear {
                                if isHoveringTerminal {
                                    isHoveringTerminal = false
                                    setWindowDraggable(true)
                                }
                            }
                            .onChange(of: model.selectedTerminal?.id) { _, newId in
                                if newId == nil && isHoveringTerminal {
                                    isHoveringTerminal = false
                                    setWindowDraggable(true)
                                }
                            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.viewSwap, value: readerAgent?.id)
    }

    /// Re-resolve the opened agent so a completion arriving mid-read fills the body in.
    /// Resolved against the full run list, not `visibleAgents` — a swept run leaves the
    /// visible set, and the reader must not freeze on its "still working" snapshot.
    private func currentAgent(_ agent: AgentRun) -> AgentRun {
        guard let id = model.selectedId else { return agent }
        return model.usage.sessionAgents(id).first { $0.id == agent.id } ?? agent
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
            HeroGlyph()
            Text("Ready when you are")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 12)
            Text("Autonomous agent & terminal sessions run right here.")
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

/// The empty state's glyph: what this panel does, said once. A still symbol rather than a
/// breathing halo — an empty screen is an invitation to act, not an ambient animation.
private struct HeroGlyph: View {
    var body: some View {
        Image(systemName: "apple.terminal")
            .font(.system(size: 40, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.accent.opacity(0.85))
            .frame(width: 74, height: 64)
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

// MARK: - Update bar

/// A fresh build is waiting — an accent-washed strip above home's footer, and nowhere
/// else. Installing is one tap; sessions return as restorable cards after the relaunch.
struct UpdateBar: View {
    let update: UpdateInfo
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text("Update ready · \(update.fromBuild) → \(update.toBuild)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onInstall) {
                Text("Install & restart")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Swap in the new build — sessions return as restorable cards")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                .selectableText()
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

/// The one prominent action: a flat accent capsule, like any prominent button on the
/// system. The colour is the emphasis — a gradient, an inner highlight and a glow on top
/// of it are three more ways to say the same thing.
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
