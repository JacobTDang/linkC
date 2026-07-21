import SwiftUI
import AppKit
import LinkCKit

// MARK: - Panel

/// The panel content: a header, a scrollable session strip, and the selected session's terminal
/// as the hero. Draws no opaque background of its own — the frosted `NSVisualEffectView` behind
/// it (set up in `StatusPanelController`) shows through as glass.
struct PanelView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let error = model.setupError {
                SetupErrorView(message: error)
            } else {
                VStack(spacing: 0) {
                    PanelHeader(model: model)
                    Divider().overlay(Theme.hairline)
                    if model.sessions.isEmpty {
                        EmptyStateView(model: model)
                    } else if model.selectedId == nil {
                        HomeView(model: model)
                    } else {
                        TerminalHero(model: model)
                    }
                    if let error = model.lastError {
                        ErrorBar(message: error)
                    }
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.selectedId != nil {
                BackButton { model.goHome() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("linkC")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(model.activeCount) running · \(model.needsYouCount) waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            LauncherMenu(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// The back chevron shown in the header while a session's terminal is on screen — returns to the
/// home overview. Styled to match the `+` launcher chrome button.
private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .fill(Theme.hover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Back to overview")
    }
}

/// The `+` launcher — new / continue / resume are the existing `AppModel` actions.
private struct LauncherMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("New session…") { model.newSession(mode: .new) }
            Button("Continue last…") { model.newSession(mode: .continueLast) }
            Button("Resume…") { model.newSession(mode: .resume) }
            Divider()
            Button("Quit linkC") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .fill(Theme.hover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                VStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        HomeCard(
                            session: session,
                            preview: model.recentOutput(session.id, lines: 3),
                            onOpen: { model.focus(session.id) },
                            onClose: { model.stop(session.id) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single session card: a status · title · path · state header line above a dim, monospaced
/// preview of the session's last few terminal rows. The whole card is the tap target.
private struct HomeCard: View {
    let session: Session
    let preview: String
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                Text(statusLabel(session.state).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.statusColor(session.state))
                    .fixedSize()
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.hover : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help("Open \(session.title)")
    }
}

/// The card's monospaced output preview. Falls back to a dim placeholder when there's nothing to
/// show yet (not started / no output), so a fresh card never reads as blank or broken.
private struct PreviewText: View {
    let text: String

    var body: some View {
        Group {
            if text.isEmpty {
                Text("starting…").foregroundStyle(Theme.textTertiary.opacity(0.7))
            } else {
                Text(text).foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(3)
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Terminal (hero)

private struct TerminalHero: View {
    let model: AppModel

    var body: some View {
        ZStack {
            TerminalContainer(session: model.selectedTerminal)
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
            if model.selectedTerminal == nil {
                Text("Select a session")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedId, initial: true) { _, _ in
            styleTerminal(model.selectedTerminal)
        }
    }

    /// Restyle the live terminal to the tokens from the panel side (the Terminal module is left
    /// untouched): SF Mono at 12.5 and a dark, glass-toned background. Note SwiftTerm drops the
    /// alpha when it converts to a cell color, so the terminal body renders opaque-dark; the
    /// glass reads at the inset margins around it rather than through the text.
    private func styleTerminal(_ session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: 0.22)
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Theme.accent.opacity(0.9))
            VStack(spacing: 5) {
                Text("No sessions yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Start a Claude Code session and it runs right here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("New session") { model.newSession(mode: .new) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A slim strip surfacing a one-off action failure without tearing down the panel. Fail loud.
private struct ErrorBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .foregroundStyle(Theme.statusError)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .overlay(Divider().overlay(Theme.hairline), alignment: .top)
    }
}

// MARK: - Button style

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .contentShape(Rectangle())
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
