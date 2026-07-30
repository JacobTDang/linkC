import SwiftUI
import LinkCKit

/// Mini-tabs riding above the open terminal: every live session as a status-dot pill, the
/// current one highlighted — tap to switch without going home. A needs-you dot breathes in
/// the strip, so another session's blocked state is visible from inside this one.
struct SessionStrip: View {
    let sessions: [Session]
    let selectedId: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessions) { session in
                    SessionTab(session: session, isCurrent: session.id == selectedId) {
                        onSelect(session.id)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }
}

/// One session pill: a 6pt status dot and the title. The current tab sits on a brighter
/// fill; needs-you dots breathe (Reduce Motion holds them steady).
private struct SessionTab: View {
    let session: Session
    let isCurrent: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pulseUp = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.statusColor(session.state))
                    .frame(width: 6, height: 6)
                    .opacity(dotOpacity)
                Text(session.title)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isCurrent
                    ? Color.white.opacity(0.10)
                    : (hovering ? Theme.hover : Color.white.opacity(0.04)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
        .help(isCurrent ? "\(session.title) — current" : "Switch to \(session.title)")
        .onAppear { restartPulse() }
        .onChange(of: session.state) { _, _ in restartPulse() }
        .onChange(of: reduceMotion) { _, _ in restartPulse() }
    }

    private var shouldPulse: Bool { session.state.bucket == .needsYou && !reduceMotion }

    private var dotOpacity: Double {
        shouldPulse ? (pulseUp ? 1.0 : 0.35) : 1.0
    }

    /// Same restart discipline as `StatusDot`: assigning inside a fresh animation cancels
    /// any prior `repeatForever`.
    private func restartPulse() {
        if shouldPulse {
            pulseUp = false
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseUp = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulseUp = false }
        }
    }
}
