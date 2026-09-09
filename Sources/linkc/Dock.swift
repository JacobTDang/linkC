import SwiftUI
import LinkCKit

/// The panel's navigation: one floating glass capsule of icon buttons at the trailing edge —
/// per Liquid Glass's rules the single element that floats above the content, replacing the
/// old five-tile rail. The selected screen is a coral pill; hover brightens the glyph.
struct Dock: View {
    let model: AppModel
    let selected: PanelScreen?

    var body: some View {
        let stack = VStack(spacing: 2) {
            DockButton(icon: "server.rack", label: "MCP Servers",
                       isSelected: selected == .mcpServers) { model.open(.mcpServers) }
            DockButton(icon: "wand.and.stars", label: "Skills",
                       isSelected: selected == .skills) { model.open(.skills) }
            DockButton(icon: "terminal", label: "Terminals",
                       isSelected: selected == .terminals) { model.open(.terminals) }
            DockButton(icon: "bubble.left.and.text.bubble.right", label: "Agent Activity & Dashboard",
                       isSelected: selected == .activity) { model.open(.activity) }
            DockButton(icon: "shippingbox", label: "Tool Servers",
                       isSelected: selected == .toolServers) { model.open(.toolServers) }
            DockButton(icon: "gearshape", label: "Settings",
                       isSelected: selected == .settings) { model.open(.settings) }
        }
        .padding(5)

        stack.background(fallbackCapsule)
    }

    /// Pre-Tahoe stand-in for the glass effect: a flat wash and one hairline, plus the
    /// cast shadow. The dock is the one element that genuinely floats, so it is the one
    /// element that earns a shadow.
    private var fallbackCapsule: some View {
        Capsule()
            .fill(Color.white.opacity(0.10))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.45), radius: 14, y: 10)
    }
}

/// One dock icon: a 34pt circular hit target. Selection is a flat coral disc; hover raises
/// the glyph over the shared wash. The label lives in the tooltip.
private struct DockButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .white : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(Theme.accent)
                    } else if hovering {
                        Circle().fill(Theme.hover)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
        .help(label)
    }
}
