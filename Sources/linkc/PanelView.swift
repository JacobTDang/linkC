import SwiftUI
import AppKit
import LinkCKit

// MARK: - Panel

/// The panel content: a sidebar of projects and sessions beside a right pane showing the
/// selected terminal, an open screen, or the launcher. Draws no opaque background of its own —
/// the frosted `NSVisualEffectView` behind it (set up in `StatusPanelController`) shows through
/// as glass, and nothing inside is outlined: content floats as soft fills of the same material.
struct PanelView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let error = model.setupError {
                SetupErrorView(message: error)
            } else {
                VStack(spacing: 0) {
                    // At or above the split breakpoint the sidebar is always there, beside the
                    // right pane. Below it, the sidebar fills the panel and a session or screen
                    // replaces it, with a back button.
                    GeometryReader { geo in
                        ZStack {
                            if geo.size.width >= Theme.splitBreakpoint {
                                HStack(spacing: 0) {
                                    Sidebar(model: model, isSplit: true)
                                        .frame(width: Theme.sidebarWidth)
                                    Rectangle()
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: 1)
                                    RightPane(model: model, showsBack: false)
                                }
                            } else if model.selectedId != nil || model.activeScreen != nil || model.boardProject != nil {
                                RightPane(model: model, showsBack: true)
                                    .transition(.opacity)
                            } else {
                                Sidebar(model: model, isSplit: false)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
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

/// One Equatable discriminator for the pane-swap animation.
private enum Pane: Equatable {
    case terminal, board(String), screen(PanelScreen), launcher

    @MainActor init(_ model: AppModel) {
        if let screen = model.activeScreen { self = .screen(screen) }
        else if let board = model.boardProject { self = .board(board) }
        else if model.selectedId != nil { self = .terminal }
        else { self = .launcher }
    }
}

/// Whatever is open beside the sidebar: a screen (layered over any open terminal), the selected
/// session's terminal, or the launcher when nothing is open.
private struct RightPane: View {
    let model: AppModel
    let showsBack: Bool

    var body: some View {
        ZStack {
            if let screen = model.activeScreen {
                VStack(spacing: 0) {
                    if showsBack {
                        HStack {
                            ChromeButton(systemName: "chevron.left", help: "Back") { model.goBack() }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    }
                    ScreenHost(model: model, screen: screen)
                }
                .transition(.opacity)
            } else if model.currentProject != nil {
                VStack(spacing: 0) {
                    ProjectTabStrip(model: model, onBack: showsBack ? { model.goBack() } : nil)
                    if let board = model.boardProject {
                        BoardPane(model: model, path: board)
                            .id(board)
                    } else {
                        TerminalPane(model: model, onBack: nil)
                    }
                }
                .transition(.opacity)
            } else {
                EmptyStateView(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.viewSwap, value: Pane(model))
    }
}

/// The open terminal under its header strip. The agent reader swaps in for the terminal until
/// dismissed.
private struct TerminalPane: View {
    let model: AppModel
    let onBack: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.setWindowDraggable) private var setWindowDraggable
    /// An agent opened for reading — replaces the terminal until dismissed.
    @State private var readerAgent: AgentRun?
    /// Whether the pointer is over the terminal (dragging the window is off there).
    @State private var isHoveringTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = model.selectedId, let session = model.sessions.first(where: { $0.id == id }) {
                SessionHeaderStrip(model: model, session: session, onBack: onBack) { readerAgent = $0 }
            } else if let id = model.selectedId, let shell = model.shellRows.first(where: { $0.id == id }) {
                ShellHeaderStrip(row: shell, onBack: onBack)
            }
            ZStack {
                if let readerAgent {
                    AgentReaderView(agent: currentAgent(readerAgent)) { self.readerAgent = nil }
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity))
                } else {
                    terminal
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.viewSwap, value: readerAgent?.id)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .onChange(of: model.selectedId, initial: true) { _, _ in
            readerAgent = nil
            styleTerminal(model.selectedTerminal)
        }
    }

    private var terminal: some View {
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

    /// Re-resolve the opened agent so a completion arriving mid-read fills the body in.
    /// Resolved against the full run list, not `visibleAgents` — a swept run leaves the
    /// visible set, and the reader must not freeze on its "still working" snapshot.
    private func currentAgent(_ agent: AgentRun) -> AgentRun {
        guard let id = model.selectedId else { return agent }
        return model.usage.sessionAgents(id).first { $0.id == agent.id } ?? agent
    }

    /// Restyle the live terminal to the panel's tokens: SF Mono at 12.5 and a translucent
    /// background, so the glass reads through the terminal. The font must be set first and the
    /// layer cleared last: `setupOptions()` re-stamps an opaque layer background on font changes.
    private func styleTerminal(_ session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.30)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - Screens

/// Hosts a screen opened from the sidebar, filling the right pane. The selection underneath
/// stays put, so closing the screen lands the user exactly where they were.
private struct ScreenHost: View {
    let model: AppModel
    let screen: PanelScreen

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .newSession: EmptyStateView(model: model)
        case .mcpServers: MCPServersScreen(model: model)
        case .skills: SkillsScreen(model: model)
        case .terminals: TerminalsScreen(model: model)
        case .toolServers: ToolServersScreen(model: model)
        case .settings: SettingsScreen(model: model)
        case .activity: ActivityScreen(model: model)
        }
    }
}

// MARK: - Chrome buttons and launcher

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

/// The ✎ menu in the sidebar's brand row — 1-click launch for all supported autonomous agents
/// and terminals.
struct LauncherMenu: View {
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
            ChromeGlyph(systemName: "square.and.pencil", hovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("New session, terminal, or quit")
    }
}

// MARK: - Screen content helpers

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

/// The card's monospaced output preview, sitting directly on the card fill.
/// Falls back to a dim placeholder when there's nothing to show yet, so a fresh card never reads as blank or broken.
struct PreviewText: View {
    let text: String
    var leadingPadding: CGFloat = 2

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
        .padding(.leading, leadingPadding)
    }
}

// MARK: - Empty state

/// The right pane's fallback: nothing selected, no screen open. A halo hero with the primary
/// New session action, quiet Continue/Resume beneath, recent folders as one-tap starters, and
/// a faint quit link in the corner.
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
                    FolderChip(
                        path: path,
                        action: { model.startSession(in: path) },
                        onStartWith: { agent in model.startSession(in: path, agent: agent) }
                    )
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
    var onStartWith: ((AgentKind) -> Void)? = nil

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
        .contextMenu {
            ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                Button("Start with \(kind.displayName)") {
                    onStartWith?(kind)
                }
            }
        }
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
