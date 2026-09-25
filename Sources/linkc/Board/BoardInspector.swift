import SwiftUI
import LinkCKit

/// What a hover card or the docked inspector is showing: a part or an arrow, read once from the
/// map through `BoardInspection` — never the map itself, so this view never reaches back into
/// model state.
enum BoardInspectionContent: Equatable {
    case part(BoardInspection.Part)
    case arrow(BoardInspection.Arrow)
}

/// Which pinned or hovered thing an inspection targets — a part by name, or an arrow by its key.
/// Only these two `BoardModel.Element` cases ever inspect; a dedicated type keeps every switch
/// here exhaustive over just them.
enum BoardInspectionTarget: Equatable {
    case part(String)
    case arrow(BoardModel.ArrowKey)
}

/// The body both the hover card and the docked inspector show — a part's name, kind and IN/OUT
/// rows, or an arrow's ends, label and style. No chrome of its own; callers wrap it in a card or a
/// docked panel.
struct BoardInspectionBody: View {
    let content: BoardInspectionContent

    var body: some View {
        switch content {
        case .part(let part): partBody(part)
        case .arrow(let arrow): arrowBody(arrow)
        }
    }

    @ViewBuilder
    private func partBody(_ part: BoardInspection.Part) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(part.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(kindCaption(part))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Theme.textTertiary)
            if let does = part.does, !does.isEmpty {
                Text(does)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !part.inputs.isEmpty { section("IN", rows: part.inputs, isInput: true) }
            if !part.outputs.isEmpty { section("OUT", rows: part.outputs, isInput: false) }
        }
    }

    /// `defaultSubLine(for:)`, else the bare kind name, with `· PLANNED` appended while the part
    /// doesn't exist yet.
    private func kindCaption(_ part: BoardInspection.Part) -> String {
        let base = BoardShape.defaultSubLine(for: part.kind) ?? part.kind.raw.uppercased()
        return part.planned ? "\(base) · PLANNED" : base
    }

    private func section(_ title: String, rows: [BoardInspection.Row], isInput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            ForEach(rows.indices, id: \.self) { index in row(rows[index], isInput: isInput) }
        }
    }

    private func row(_ row: BoardInspection.Row, isInput: Bool) -> some View {
        let tint = row.isControl ? Theme.boardGold : Theme.textPrimary
        return HStack(spacing: 4) {
            Text(row.signal)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            // The width, bold — or a blank the same width holds, so every row's other-end text
            // still lines up in a column whether or not that row carries a width.
            Text(row.bits.map(String.init) ?? "")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(minWidth: 20, alignment: .leading)
            Spacer(minLength: 6)
            Text((isInput ? "← " : "→ ") + row.other)
                .font(.system(size: 11))
                .foregroundStyle(row.isControl ? Theme.boardGold : Theme.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func arrowBody(_ arrow: BoardInspection.Arrow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(arrow.from) → \(arrow.to)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(styleLine(arrow))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            if !arrow.plannedEnds.isEmpty {
                Text("Planned: \(arrow.plannedEnds.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// `label · <descriptor>`, or just the descriptor with no label — the descriptor is
    /// `<bits>-bit bus` for a bus with a width, else the style's own name.
    private func styleLine(_ arrow: BoardInspection.Arrow) -> String {
        let descriptor: String
        if arrow.style == .bus, let bits = arrow.bits {
            descriptor = "\(bits)-bit bus"
        } else {
            descriptor = styleName(arrow.style)
        }
        return arrow.label.isEmpty ? descriptor : "\(arrow.label) · \(descriptor)"
    }

    private func styleName(_ style: BoardArrowStyle) -> String {
        switch style {
        case .plain: return "Plain"
        case .conditional: return "Conditional"
        case .control: return "Control"
        case .bus: return "Bus"
        }
    }
}

/// The transient hover card: a dark plane, a hairline border, 10 pt radius — the approved
/// mockup's card treatment. Never intercepts the pointer; it's a tooltip, not a control.
struct BoardHoverCard: View {
    let content: BoardInspectionContent
    static let width: CGFloat = 240

    var body: some View {
        BoardInspectionBody(content: content)
            .padding(12)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.boardCardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .allowsHitTesting(false)
    }
}

/// The docked inspector: a 260 pt panel at the Board's right edge, full height, outside the
/// zoomed content so it neither pans nor zooms. Its own opaque plane means pointer events over it
/// never reach the canvas beneath.
struct BoardDockedInspector: View {
    let content: BoardInspectionContent
    let edit: () -> Void
    let close: () -> Void
    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                BoardInspectionBody(content: content)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.boardCardFill)
        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1) }
        .shadow(color: .black.opacity(0.4), radius: 14, x: -2)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button("Edit…", action: edit)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
