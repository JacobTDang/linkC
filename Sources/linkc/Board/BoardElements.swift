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

/// A component's box: its kind's shape (a cylinder for a database, a pipe for a queue, a bucket
/// for storage, a server for a host, a dashed cloud for an external service, a card for a
/// service), solid when it exists, dashed while planned, dimmed when linkC looked for it and did
/// not find it, a green dot when it is running now.
struct ComponentBox: View {
    let component: BoardComponent
    let status: ComponentStatus?
    let isSelected: Bool

    private static let width = CGFloat(BoardGeometry.componentSize.x)
    private static let height = CGFloat(BoardGeometry.componentSize.y)

    private var isMissing: Bool { status == .missing && !component.planned }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shape
            BoardShape.accents(for: component.kind)
            content
                .padding(.leading, inset.leading)
                .frame(width: Self.width, height: Self.height, alignment: .leading)
                .offset(y: inset.verticalOffset)
        }
        .frame(width: Self.width, height: Self.height)
        .overlay(alignment: .topTrailing) {
            if status == .present {
                Circle().fill(Theme.statusRunning).frame(width: 6, height: 6).padding(7)
            }
        }
        .opacity(isMissing ? 0.5 : 1)
        .help(help)
    }

    /// A database or cache draws as two separate shapes, body then rim, exactly as the mockup
    /// paints them: a `<path>` for the body, then an `<ellipse>` on top for the rim — never one
    /// combined path, which is what made the rim read as a hole (opposite winding) with a stroked
    /// line across it (the body's own closing edge).
    @ViewBuilder
    private var shape: some View {
        switch component.kind {
        case .database, .cache:
            BoardShape.cylinderBody.fill(fillColor(Theme.boardBox))
            BoardShape.cylinderBody.stroke(strokeColor, style: strokeStyle)
            BoardShape.cylinderRim.fill(fillColor(Theme.boardCylinderRim))
            BoardShape.cylinderRim.stroke(strokeColor, style: strokeStyle)
        default:
            BoardShape.path(for: component.kind).fill(fillColor(Theme.boardBox))
            BoardShape.path(for: component.kind).stroke(strokeColor, style: strokeStyle)
        }
    }

    private func fillColor(_ solid: Color) -> Color { component.planned ? Color.clear : solid }
    private var strokeStyle: StrokeStyle { StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: dash) }

    private var content: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subLine)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let agent = BoardTech.agent(for: component) {
            AgentLogoView(agent: agent, size: 24)
        } else if let info = BoardTech.resolve(component) {
            TechLogoView(info: info, size: 24)
        } else {
            Image(systemName: component.kind.glyph)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
        }
    }

    /// `KIND · <tech display name>`; else `KIND · <reachedBy>`, truncated; else `KIND`.
    private var subLine: String {
        let kind = component.kind.raw.uppercased()
        if let agent = BoardTech.agent(for: component) { return "\(kind) · \(agent.displayName)" }
        if let info = BoardTech.resolve(component) { return "\(kind) · \(info.displayName)" }
        if let reachedBy = component.reachedBy, !reachedBy.isEmpty { return "\(kind) · \(reachedBy)" }
        return kind
    }

    /// Where the icon and text sit inside the kind's shape — leading inset and a small vertical
    /// nudge, both taken from the mockup's per-kind geometry.
    private var inset: (leading: CGFloat, verticalOffset: CGFloat) {
        switch component.kind {
        case .database, .cache: return (14, 2)
        case .queue: return (16, 0)
        case .storage: return (18, 0)
        case .host: return (14, 0)
        case .external: return (26, 6)
        default: return (14, 0)
        }
    }

    private var strokeColor: Color {
        isSelected ? Theme.accent : (component.planned ? Theme.textTertiary : Theme.boardBoxStroke)
    }

    /// Planned draws dashed, as always; an external component draws dashed too — it lives outside
    /// the system — unless selected, when the accent outline takes over solid.
    private var dash: [CGFloat] {
        guard !isSelected else { return [] }
        return (component.planned || component.kind == .external) ? [4, 3] : []
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

/// The kind's shape, in the component box's own 176×84 space — translated from the approved
/// mockup's SVG generator. Every shape fits the same box so the layout grid never has to know
/// which kind it is placing.
enum BoardShape {
    private static let w = CGFloat(BoardGeometry.componentSize.x)
    private static let h = CGFloat(BoardGeometry.componentSize.y)

    static func path(for kind: ComponentKind) -> Path {
        switch kind {
        case .database, .cache: return cylinderBody
        case .queue: return pipe
        case .storage: return bucket
        case .host: return server
        case .external: return cloud
        default: return card
        }
    }

    /// The decoration that rides on top of the shape and never changes colour with state: a
    /// queue's chevrons, a host's rack lines, a cache's second, dashed rim.
    @ViewBuilder
    static func accents(for kind: ComponentKind) -> some View {
        switch kind {
        case .queue:
            ForEach(0..<3, id: \.self) { i in chevron(atX: w - 40 + CGFloat(i) * 8) }
        case .host:
            ForEach(0..<3, id: \.self) { i in rackLine(atY: 26 + CGFloat(i) * 15) }
        case .cache:
            cacheRim
        default:
            EmptyView()
        }
    }

    /// A cylinder's body: the side walls plus the bottom elliptical arc, left open along the top
    /// — exactly the mockup's path (`M x top L x bot A w/2 ry 0 0 0 x+w bot L x+w top`, never
    /// closed). Fill implicitly closes it along that top edge; stroke does not draw that edge, so
    /// no line crosses the rim. The rim itself is `cylinderRim`, a separate shape drawn on top.
    static var cylinderBody: Path {
        let ry: CGFloat = 11
        let top = ry, bot = h - ry
        let kappa: CGFloat = 0.5522847498
        let rx = w / 2
        var p = Path()
        p.move(to: CGPoint(x: 0, y: top))
        p.addLine(to: CGPoint(x: 0, y: bot))
        p.addCurve(to: CGPoint(x: w / 2, y: bot + ry),
                  control1: CGPoint(x: 0, y: bot + ry * kappa), control2: CGPoint(x: w / 2 - rx * kappa, y: bot + ry))
        p.addCurve(to: CGPoint(x: w, y: bot),
                  control1: CGPoint(x: w / 2 + rx * kappa, y: bot + ry), control2: CGPoint(x: w, y: bot + ry * kappa))
        p.addLine(to: CGPoint(x: w, y: top))
        return p
    }

    /// A cylinder's top rim: its own ellipse, drawn and stroked as a separate shape on top of the
    /// body — never unioned into the same path, which is what made the two subpaths' opposite
    /// windings read as a hole.
    static var cylinderRim: Path {
        let ry: CGFloat = 11
        var p = Path()
        p.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: ry * 2))
        return p
    }

    /// A pipe: a capsule, with the chevrons drawn separately by `accents`.
    private static var pipe: Path {
        Path(roundedRect: CGRect(x: 0, y: 12, width: w, height: h - 24), cornerRadius: h / 2 - 12)
    }

    /// A bucket: a trapezoid, wider at the top by an 8 pt taper on each side.
    private static var bucket: Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 8))
        p.addLine(to: CGPoint(x: w - 4, y: 8))
        p.addLine(to: CGPoint(x: w - 12, y: h - 8))
        p.addLine(to: CGPoint(x: 12, y: h - 8))
        p.closeSubpath()
        return p
    }

    /// A server: a card, with the rack lines drawn separately by `accents`.
    private static var server: Path {
        Path(roundedRect: CGRect(x: 0, y: 4, width: w, height: h - 8), cornerRadius: 6)
    }

    /// A card: the default shape, for a service and any kind linkC doesn't otherwise draw.
    private static var card: Path {
        Path(roundedRect: CGRect(x: 0, y: 8, width: w, height: h - 16), cornerRadius: 12)
    }

    /// A cloud, its outline four circular arcs — computed once for the fixed 176×84 box, from the
    /// mockup generator's `shape()`. Each lobe's large arc must bulge outward, not cut through the
    /// cloud's inside: the SVG source's sweep-flag 0 is counter-clockwise on screen (a y-down
    /// space), which is `clockwise: true` here — `Path.addArc`'s `clockwise` is defined against
    /// the flipped, y-up Core Graphics convention, so it inverts relative to what is drawn.
    private static var cloud: Path {
        var p = Path()
        p.move(to: CGPoint(x: 36, y: 78))
        p.addLine(to: CGPoint(x: 148, y: 78))
        p.addArc(center: CGPoint(x: 145.927, y: 57.103), radius: 21,
                 startAngle: .degrees(84.334), endAngle: .degrees(-73.190), clockwise: true)
        p.addArc(center: CGPoint(x: 123.008, y: 37.683), radius: 29,
                 startAngle: .degrees(-1.350), endAngle: .degrees(-149.581), clockwise: true)
        p.addArc(center: CGPoint(x: 78.696, y: 38.886), radius: 25,
                 startAngle: .degrees(-39.452), endAngle: .degrees(-171.058), clockwise: true)
        p.addArc(center: CGPoint(x: 53.000, y: 56.500), radius: 21.523,
                 startAngle: .degrees(-87.337), endAngle: .degrees(-267.337), clockwise: true)
        p.closeSubpath()
        return p
    }

    private static func chevron(atX x: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: x, y: 35))
            p.addLine(to: CGPoint(x: x + 5, y: 42))
            p.addLine(to: CGPoint(x: x, y: 49))
        }
        .stroke(Theme.textTertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private static func rackLine(atY y: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: w - 36, y: y))
            p.addLine(to: CGPoint(x: w - 14, y: y))
        }
        .stroke(Theme.textTertiary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// A cache's second rim: a database's cylinder, plus this dashed ellipse below the solid one,
    /// marking it as a stack rather than a single store.
    private static var cacheRim: some View {
        Path { p in p.addEllipse(in: CGRect(x: 0, y: 16, width: w, height: 22)) }
            .stroke(Theme.boardBoxStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}

/// A sticky note: clamped to 7 lines on the card, since it never grows in place; a long note
/// shows in full only as a tooltip, on hover.
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
