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
                    } else {
                        SessionStrip(model: model)
                        Divider().overlay(Theme.hairline)
                        TerminalHero(model: model)
                    }
                    if let error = model.lastError {
                        ErrorBar(message: error)
                    }
                }
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
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
        .padding(.vertical, 12)
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

// MARK: - Session strip

private struct SessionStrip: View {
    let model: AppModel

    /// Hug the rows up to a cap, then scroll — so the terminal keeps the tall remaining height.
    private var height: CGFloat {
        let rowHeight: CGFloat = 46
        let spacing: CGFloat = 4
        let vpad: CGFloat = 16
        let n = CGFloat(model.sessions.count)
        let content = n * rowHeight + max(0, n - 1) * spacing + vpad
        return min(content, 232)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(model.sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: model.selectedId == session.id,
                        onSelect: { model.focus(session.id) },
                        onClose: { model.stop(session.id) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.15), value: model.selectedId)
    }
}

private struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: session.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
            .help("Close session")
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isSelected ? Theme.selection : (hovering ? Theme.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(statusLabel(session.state))
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
