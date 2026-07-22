import SwiftUI
import LinkCKit

/// Design tokens for the panel — one sheet of dark glass, no outlines. Content floats as soft
/// fills of the same material; color appears only where state demands it. Every color and size
/// in `PanelView` derives from here so the surface reads as one cohesive system.
enum Theme {
    // Text, on the dark glass.
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    /// Claude coral (~#D97757) — the single accent.
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)

    // Status colors.
    static let statusRunning = Color(red: 0.369, green: 0.710, blue: 0.612) // ~#5EB59C
    static let statusNeedsYou = accent
    static let statusIdle = textTertiary
    static let statusError = Color(red: 0.85, green: 0.35, blue: 0.33)
    /// Soft gold for a context hairline nearing auto-compact (~#E3C169).
    static let contextWarn = Color(red: 0.89, green: 0.757, blue: 0.412)

    // Surfaces: soft fills, never borders — cards read as raised glass, not boxes.
    /// A card's surface: a faint top-lit vertical gradient, so it reads as a soft pane of
    /// glass rather than a flat slab. Needs-you cards carry the one colored wash; hover
    /// brightens either variant slightly.
    static func cardSurface(needsYou: Bool, hovering: Bool) -> LinearGradient {
        let top: Color = needsYou
            ? accent.opacity(hovering ? 0.18 : 0.13)
            : Color.white.opacity(hovering ? 0.10 : 0.065)
        let bottom: Color = needsYou
            ? accent.opacity(hovering ? 0.10 : 0.06)
            : Color.white.opacity(hovering ? 0.055 : 0.03)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
    /// A barely-there wash behind bare chrome glyphs and restorable rows on hover.
    static let hover = Color.white.opacity(0.07)
    /// The inline error strip's tinted surface.
    static let errorWash = statusError.opacity(0.12)

    // Corner radii.
    static let panelRadius: CGFloat = 16
    static let terminalRadius: CGFloat = 12
    static let rowRadius: CGFloat = 12

    /// Fixed height reserved for the card's 3-line output preview so cards never jitter as
    /// output changes.
    static let previewHeight: CGFloat = 42

    // Two-column layout (home + empty state): a left column for identity/primary action, a
    // quiet right rail reserved for future navigation (MCP Servers, Skills, Settings). The rail
    // hides below `railBreakpoint` so it never crowds the panel at its 300pt minimum width, and
    // otherwise scales with the panel between `railMinWidth` and `railMaxWidth`.
    static let railBreakpoint: CGFloat = 380
    static let railMinWidth: CGFloat = 76
    static let railMaxWidth: CGFloat = 108
    static let railFraction: CGFloat = 0.22
    static let columnSpacing: CGFloat = 14

    /// The rail's width for a given panel width — a fraction of the whole, clamped so it
    /// neither crushes down to nothing nor grows to dominate the panel.
    static func railWidth(for totalWidth: CGFloat) -> CGFloat {
        min(max(totalWidth * railFraction, railMinWidth), railMaxWidth)
    }

    /// The metrics rail's tile fill — flat and faint, quieter than a card's lit gradient, since
    /// the rail is secondary to the left column. No hover/needs-you variants: these tiles are
    /// static placeholders, not live state.
    static let railTileSurface = Color.white.opacity(0.045)

    // Motion — one orchestrated system. Springs/slides are gated behind Reduce Motion at the call
    // site (which swaps them for a crossfade); these are the tuned parameters everything shares.
    static let sectionSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let hoverEase = Animation.easeOut(duration: 0.15)
    static let viewSwap = Animation.easeInOut(duration: 0.2)

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
