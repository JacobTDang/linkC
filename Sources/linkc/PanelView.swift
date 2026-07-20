import SwiftUI
import LinkCKit

// MARK: - Theme

/// A small, self-contained dark palette so the panel reads as one cohesive surface
/// regardless of the system appearance.
private enum Theme {
    static let bg = Color(red: 0.086, green: 0.090, blue: 0.106)
    static let surface = Color.white.opacity(0.05)
    static let surfaceHover = Color.white.opacity(0.09)
    static let selected = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.5)
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.98)

    static let idleDot = Color.white.opacity(0.35)
    static let activeDot = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let needsYouDot = Color(red: 0.98, green: 0.75, blue: 0.14)

    static func dot(_ bucket: SessionState.Bucket) -> Color {
        switch bucket {
        case .idle: return idleDot
        case .active: return activeDot
        case .needsYou: return needsYouDot
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }

    @ViewBuilder private var content: some View {
        if let error = model.setupError {
            SetupErrorView(message: error)
        } else if model.sessions.isEmpty {
            EmptyStateView(model: model)
        } else {
            SessionTabStrip(model: model)
            Divider().overlay(Theme.hairline)
            TerminalContainer(session: model.selectedTerminal)
                .background(Theme.bg)
            StatusBar(model: model)
        }
    }
}

// MARK: - Tab strip

private struct SessionTabStrip: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        SessionTab(
                            session: session,
                            isSelected: model.selectedId == session.id,
                            onSelect: { model.focus(session.id) },
                            onClose: { model.stop(session.id) }
                        )
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 10)
            }
            LauncherMenu(model: model)
                .padding(.trailing, 10)
        }
        .frame(height: 44)
        .animation(.easeInOut(duration: 0.15), value: model.selectedId)
    }
}

private struct SessionTab: View {
    let session: Session
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.dot(session.state.bucket))
                .frame(width: 7, height: 7)
            Text(session.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.selected : (hovering ? Theme.surfaceHover : Theme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(statusLabel(session.state))
    }
}

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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("\(model.activeCount) running · \(model.needsYouCount) waiting")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.needsYouDot)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.bg)
        .overlay(Divider().overlay(Theme.hairline), alignment: .top)
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.accent.opacity(0.9))
            VStack(spacing: 5) {
                Text("No sessions yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Start a Claude Code session and it runs right here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Button("New session…") { model.newSession(mode: .new) }
                    .buttonStyle(PrimaryButtonStyle())
                Menu {
                    Button("Continue last…") { model.newSession(mode: .continueLast) }
                    Button("Resume…") { model.newSession(mode: .resume) }
                } label: {
                    Text("More")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 4)
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.needsYouDot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .topTrailing) {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .padding(12)
        }
    }
}

// MARK: - Setup error

private struct SetupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.needsYouDot)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Button style

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1))
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
