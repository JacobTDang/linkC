import AppKit
import SwiftUI
import LinkCKit

extension ComponentKind {
    /// The kind's glyph. Anything linkC does not know draws as a service.
    var glyph: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .cache: return "bolt.horizontal"
        case .queue: return "tray.full"
        case .storage: return "externaldrive"
        case .host: return "server.rack"
        case .external: return "cloud"
        default: return "shippingbox"
        }
    }
}

/// A component's box: solid when it exists, dashed while planned, dimmed when linkC looked for
/// it and did not find it, a green dot when it is running now.
struct ComponentBox: View {
    let component: BoardComponent
    let status: ComponentStatus?
    let isSelected: Bool

    private var isMissing: Bool { status == .missing && !component.planned }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: component.kind.glyph)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let reachedBy = component.reachedBy, !reachedBy.isEmpty {
                    Text(reachedBy)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if status == .present {
                Circle().fill(Theme.statusRunning).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: CGFloat(BoardGeometry.componentSize.x), height: CGFloat(BoardGeometry.componentSize.y))
        .background(RoundedRectangle(cornerRadius: 10).fill(component.planned ? Color.clear : Theme.boardBox))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Theme.accent : (component.planned ? Theme.textTertiary : Theme.boardBoxStroke),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: component.planned && !isSelected ? [4, 3] : [])))
        .opacity(isMissing ? 0.5 : 1)
        .help(help)
    }

    private var help: String {
        var parts = [component.kind.raw]
        if let does = component.does, !does.isEmpty { parts.append(does) }
        switch status {
        case .present: parts.append("running now")
        case .missing: parts.append("linkC looked for this and did not find it")
        case .unchecked, nil: parts.append("linkC cannot check this one")
        }
        if component.planned { parts.append("planned — does not exist yet") }
        return parts.joined(separator: " · ")
    }
}

/// A sticky note: a long note is cut short here and shown in full when selected.
struct NoteCard: View {
    let note: BoardNote
    let isSelected: Bool

    var body: some View {
        Text(note.text.isEmpty ? "Note" : note.text)
            .font(.system(size: 11))
            .foregroundStyle(note.text.isEmpty ? Theme.noteText.opacity(0.4) : Theme.noteText)
            .lineLimit(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .frame(width: CGFloat(BoardGeometry.noteSize.x), height: CGFloat(BoardGeometry.noteSize.y))
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.noteFill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
            .help(note.text)
    }
}

/// A heading or label on the canvas.
struct TextLabel: View {
    let text: BoardText
    let isSelected: Bool

    var body: some View {
        Text(text.text)
            .font(TextLabel.font(text.style))
            .foregroundStyle(text.style == .title ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: CGFloat(max(text.width, BoardPoint.grid)),
                   height: CGFloat(BoardGeometry.textHeight(text.style)), alignment: .leading)
            .overlay(Rectangle().strokeBorder(isSelected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1))
    }

    static func font(_ style: BoardTextStyle) -> Font {
        style == .title ? .system(size: 20, weight: .bold) : .system(size: 12, weight: .medium)
    }

    /// The width a text needs, measured once when its words change — never by reading layout
    /// back, so measuring can never cause a write.
    static func width(of text: String, style: BoardTextStyle) -> Int {
        let font = style == .title ? NSFont.systemFont(ofSize: 20, weight: .bold) : NSFont.systemFont(ofSize: 12, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return Int(measured.rounded(.up)) + 4
    }
}

/// A frame's label, sitting on its top border. Dragging it moves the frame.
struct FrameLabel: View {
    let label: String
    let isSelected: Bool

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.boardBackground))
            .fixedSize()
    }
}

/// A frame's resize grip, at its bottom-right corner.
struct FrameGrip: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}
