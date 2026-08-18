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

    // Surfaces: the content plane. Cards are near-opaque dark planes resting ON the glass
    // sheet — darker than the sheet so they anchor, never translucent washes that dissolve
    // into it (glass is reserved for the one floating element, the dock).
    /// A card's plane: a top-lit dark gradient, slightly lighter on hover. Needs-you cards
    /// burn a warm coral-tinted plane instead.
    static func cardSurface(needsYou: Bool, hovering: Bool) -> LinearGradient {
        let top: Color = needsYou
            ? Color(red: hovering ? 0.27 : 0.227, green: hovering ? 0.16 : 0.133, blue: hovering ? 0.12 : 0.102).opacity(0.82)
            : Color(red: hovering ? 0.118 : 0.086, green: hovering ? 0.125 : 0.094, blue: hovering ? 0.145 : 0.114).opacity(0.85)
        let bottom: Color = needsYou
            ? Color(red: hovering ? 0.19 : 0.157, green: hovering ? 0.125 : 0.102, blue: hovering ? 0.10 : 0.086).opacity(0.85)
            : Color(red: hovering ? 0.098 : 0.071, green: hovering ? 0.106 : 0.078, blue: hovering ? 0.122 : 0.094).opacity(0.88)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    /// The plane's edge: a hairline stroke that rim-lights the top and fades down the sides,
    /// so cards read as lit objects, not outlined boxes. Needs-you edges glow warm.
    static func cardStroke(needsYou: Bool) -> LinearGradient {
        let top: Color = needsYou
            ? Color(red: 1.0, green: 0.64, blue: 0.50).opacity(0.18)
            : Color.white.opacity(0.10)
        let bottom: Color = needsYou ? accent.opacity(0.10) : Color.white.opacity(0.03)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    /// The plane's soft cast shadow onto the sheet.
    static let planeShadow = Color.black.opacity(0.28)
    /// The vignette's edge darkening — grounds the sheet without reading as a border.
    static let vignette = Color.black.opacity(0.16)
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

/// The shared card treatment: the content plane's fill with its cast shadow, plus the
/// rim-lit hairline edge. Applied outside any `clipShape` so the shadow survives clipping.
private struct PlaneCard: ViewModifier {
    let needsYou: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(Theme.cardSurface(needsYou: needsYou, hovering: hovering))
                    .shadow(color: Theme.planeShadow, radius: 6, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke(needsYou: needsYou), lineWidth: 1)
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
