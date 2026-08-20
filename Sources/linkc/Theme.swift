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

    // Surfaces: the content plane. One flat translucent fill over the sheet — the model is
    // Control Center, whose tiles are a single wash of light on the material with no
    // gradient, no border and no shadow. Depth comes from the material behind them, not
    // from painting depth onto each row; stacking a gradient, a rim stroke and a drop
    // shadow on every row in a list is what makes a panel look busy at a glance.
    /// A card's plane. Warm white, so the plane reads as a different shade from the neutral
    /// sheet rather than as a grey box. State is one axis — how much light the tile holds.
    static func cardSurface(needsYou: Bool, hovering: Bool) -> Color {
        // Attention is the accent itself, flat, like a Control Center toggle that is on.
        if needsYou { return accent.opacity(hovering ? 0.22 : 0.16) }
        return Color(red: 1.0, green: 0.94, blue: 0.88).opacity(hovering ? 0.10 : 0.055)
    }

    /// A barely-there wash behind bare chrome glyphs and restorable rows on hover.
    static let hover = Color.white.opacity(0.07)
    /// The inline error strip's tinted surface.
    static let errorWash = statusError.opacity(0.12)

    /// Content stops stretching past this — the reading-width cap for lists and screens.
    static let contentMaxWidth: CGFloat = 560

    // Corner radii.
    static let panelRadius: CGFloat = 16
    static let terminalRadius: CGFloat = 12
    static let rowRadius: CGFloat = 12

    /// Fixed height reserved for the card's 3-line output preview so cards never jitter as
    /// output changes.
    static let previewHeight: CGFloat = 42

    // The dock: one floating glass capsule of icon buttons at the panel's trailing edge —
    // the single element that truly floats over the sheet. It hides below `dockBreakpoint`
    // so it never crowds the panel at its 300pt minimum width.
    static let dockBreakpoint: CGFloat = 360
    /// Trailing space content reserves while the dock is visible: the capsule (44) plus its
    /// margin and a breathing gap to the content column.
    static let dockInset: CGFloat = 62

    // The sidebar split: with a terminal open and at least `splitBreakpoint` of pane width,
    // the home list rides beside the terminal as a fixed column instead of the mini-tab strip.
    static let splitBreakpoint: CGFloat = 600
    static let sidebarWidth: CGFloat = 260

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

/// The shared card treatment: one flat translucent fill, nothing else.
private struct PlaneCard: ViewModifier {
    let needsYou: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(Theme.cardSurface(needsYou: needsYou, hovering: hovering))
            )
    }
}

extension View {
    /// Render this content as a card on the content plane.
    func planeCard(needsYou: Bool = false, hovering: Bool = false) -> some View {
        modifier(PlaneCard(needsYou: needsYou, hovering: hovering))
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
