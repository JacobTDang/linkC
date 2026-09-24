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
    static let statusError = Color(red: 0.85, green: 0.35, blue: 0.33)
    /// Soft gold for a context hairline nearing auto-compact (~#E3C169).
    static let contextWarn = Color(red: 0.89, green: 0.757, blue: 0.412)

    /// Native brand colors for each AI agent kind.
    static func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .claude: return Color(red: 217/255, green: 119/255, blue: 87/255) // #D97757
        case .agy: return Color(red: 122/255, green: 162/255, blue: 247/255)   // #7AA2F7
        case .cursor: return Color(red: 0/255, green: 229/255, blue: 255/255)  // #00E5FF
        case .codex: return Color(red: 16/255, green: 163/255, blue: 127/255)  // #10A37F
        case .shell: return Color(white: 0.55)
        }
    }

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

    // The sidebar split: at least `splitBreakpoint` of panel width keeps the sidebar visible as
    // a fixed column beside the right pane; below it, the sidebar and the right pane trade
    // places, with a back button.
    static let splitBreakpoint: CGFloat = 600
    static let sidebarWidth: CGFloat = 260

    // Motion — one orchestrated system. Springs/slides are gated behind Reduce Motion at the call
    // site (which swaps them for a crossfade); these are the tuned parameters everything shares.
    static let sectionSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let hoverEase = Animation.easeOut(duration: 0.15)
    static let viewSwap = Animation.easeInOut(duration: 0.2)

    // The board: a quiet dark canvas, a faint dot grid, and warm sticky notes.
    static let boardBackground = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let boardDot = Color.white.opacity(0.075)
    static let boardFrameFill = Color.white.opacity(0.02)
    static let boardFrameStroke = Color.white.opacity(0.13)
    static let boardArrow = Color.white.opacity(0.45)
    static let boardBox = Color(red: 0.149, green: 0.149, blue: 0.169)
    static let boardBoxStroke = Color.white.opacity(0.09)
    /// A cylinder's top rim, lighter than the box fill so it reads as the lid.
    static let boardCylinderRim = Color(red: 0.173, green: 0.173, blue: 0.204)
    static let noteFill = Color(red: 0.231, green: 0.204, blue: 0.137)
    static let noteText = Color(red: 0.937, green: 0.886, blue: 0.749)

    // The new AI-agent and hardware kinds' accent outlines (from the approved palettes mockup).
    /// Router, control unit and human-in-the-loop outlines (~#E6C07B).
    static let boardGold = Color(red: 0.902, green: 0.753, blue: 0.482)
    /// The state kind's outline (~#B39DDB).
    static let boardViolet = Color(red: 0.702, green: 0.616, blue: 0.859)
    /// MCP and start-pill outlines (~#7CC4A0).
    static let boardGreen = Color(red: 0.486, green: 0.769, blue: 0.627)
    /// Every hardware kind's outline (~#8A9BB8).
    static let boardHardwareStroke = Color(red: 0.541, green: 0.608, blue: 0.722)
    /// A conditional or control arrow's dashed line, arrowhead and pill text — the same gold as
    /// the router and control unit outlines above.
    static let boardConditional = boardGold

    // The new AI-agent kinds' own glyph colours (from the approved palettes mockup).
    /// The agent kind's sparkle glyph (~#E8A27F).
    static let boardAgentGlyph = Color(red: 0.910, green: 0.635, blue: 0.498)
    /// The tool kind's wrench glyph, and the vector store's dot grid and memory's history glyph
    /// (~#9FB4D8).
    static let boardGlyphBlue = Color(red: 0.624, green: 0.706, blue: 0.847)
    /// The prompt kind's document glyph (~#C9B27C).
    static let boardPromptGlyph = Color(red: 0.788, green: 0.698, blue: 0.486)
    /// The clock kind's square-wave glyph (~#8AB4F8).
    static let boardClockGlyph = Color(red: 0.541, green: 0.706, blue: 0.973)
    /// A bus arrow's slash mark and bit-width digits — kind-neutral, unlike the line itself
    /// (~#C9C9D3).
    static let boardBusMark = Color(red: 0.788, green: 0.788, blue: 0.827)
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

