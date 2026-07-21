import SwiftUI
import LinkCKit

/// Design tokens for the panel — a single dark, glass-forward palette and type/spacing scale.
/// Every color and size in `PanelView` derives from here so the frosted surface reads as one
/// cohesive system regardless of the system appearance.
enum Theme {
    // Text, on the dark glass.
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    /// The glass-edge hairline used for dividers and 1px borders.
    static let hairline = Color.white.opacity(0.08)

    /// Claude coral (~#D97757) — the single accent.
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)

    // Status colors.
    static let statusRunning = Color(red: 0.369, green: 0.710, blue: 0.612) // ~#5EB59C
    static let statusNeedsYou = accent
    static let statusIdle = textTertiary
    static let statusError = Color(red: 0.85, green: 0.35, blue: 0.33)

    /// The selected-row highlight — a soft coral wash.
    static let selection = accent.opacity(0.16)
    /// A barely-there hover wash for rows and chrome buttons.
    static let hover = Color.white.opacity(0.05)

    // Corner radii.
    static let panelRadius: CGFloat = 16
    static let terminalRadius: CGFloat = 10
    static let rowRadius: CGFloat = 8

    /// Dot / label color for a concrete session state. `.error` is called out in red even
    /// though it shares the `needsYou` bucket; every other state maps by its bucket.
    static func statusColor(_ state: SessionState) -> Color {
        if state == .error { return statusError }
        switch state.bucket {
        case .idle: return statusIdle
        case .active: return statusRunning
        case .needsYou: return statusNeedsYou
        }
    }
}

/// The signature: a living status indicator. An 8pt dot in the state's color over a soft outer
/// glow — `needsYou` gently pulses the glow (0.4↔1 over ~1.2s), `active` glows steadily, `idle`
/// has no glow. Honors Reduce Motion (steady glow instead of a pulse).
struct StatusDot: View {
    let state: SessionState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseUp = false

    private let dotSize: CGFloat = 8
    private let boxSize: CGFloat = 18   // leaves room for the blurred glow

    var body: some View {
        let color = Theme.statusColor(state)
        return ZStack {
            Circle()
                .fill(color)
                .frame(width: dotSize, height: dotSize)
                .blur(radius: 4)
                .opacity(glowOpacity)
            Circle()
                .fill(color)
                .frame(width: dotSize, height: dotSize)
        }
        .frame(width: boxSize, height: boxSize)
        .onAppear { restartPulse() }
        .onChange(of: state) { _, _ in restartPulse() }
        .onChange(of: reduceMotion) { _, _ in restartPulse() }
    }

    private var shouldPulse: Bool { state.bucket == .needsYou && !reduceMotion }

    private var glowOpacity: Double {
        switch state.bucket {
        case .idle: return 0
        case .active: return 0.85
        case .needsYou: return reduceMotion ? 0.9 : (pulseUp ? 1.0 : 0.4)
        }
    }

    /// Reset the glow, then — only when this state pulses — kick off an autoreversing repeat.
    /// Setting `pulseUp` inside a fresh animation cancels any prior `repeatForever`.
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
