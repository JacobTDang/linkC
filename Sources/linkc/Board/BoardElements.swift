import AppKit
import SwiftUI
import LinkCKit

extension ComponentKind {
    /// The kind's glyph, an SF Symbol shown in menus and pickers. Anything linkC does not know
    /// draws as a service. The component's own face may draw something richer (a logo, or a
    /// hand-drawn glyph for `mcp`) — see `ComponentBox.icon`.
    var glyph: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .table: return "tablecells"
        case .cache: return "bolt.horizontal"
        case .queue: return "tray.full"
        case .storage: return "externaldrive"
        case .host: return "server.rack"
        case .external: return "cloud"
        case .agent: return "sparkle"
        case .model: return "cpu"
        case .tool: return "wrench.adjustable"
        case .mcp: return "cable.connector"
        case .router: return "arrow.triangle.branch"
        case .start: return "play.circle"
        case .end: return "stop.circle"
        case .vectorStore: return "square.stack.3d.up"
        case .memory: return "clock.arrow.circlepath"
        case .prompt: return "doc.text"
        case .state: return "curlybraces"
        case .human: return "person"
        case .alu: return "function"
        case .mux: return "arrow.triangle.merge"
        case .demux: return "arrow.triangle.branch"
        case .register: return "square.stack"
        case .ram: return "memorychip"
        case .control: return "slider.horizontal.3"
        case .adder: return "plus.circle"
        case .decoder: return "list.bullet.rectangle"
        case .clock: return "waveform.path"
        case .bus: return "arrow.left.arrow.right"
        default: return "shippingbox"
        }
    }
}

/// A component's box: its kind's shape (a cylinder for a database, a pipe for a queue, a bucket
/// for storage, a server for a host, a dashed cloud for an external service, a card for a
/// service — and, for the AI-agent and hardware kinds, the shapes in the approved palettes
/// mockup), solid when it exists, dashed while planned, dimmed when linkC looked for it and did
/// not find it, a green dot when it is running now.
struct ComponentBox: View {
    let component: BoardComponent
    let status: ComponentStatus?
    let isSelected: Bool

    private static let width = CGFloat(BoardGeometry.componentSize.x)
    private static let height = CGFloat(BoardGeometry.componentSize.y)

    /// The box's actual drawn width and height: `BoardGeometry.size(of:)` for a table, which grows
    /// to fit its columns; `Self.width`/`Self.height` (the fixed 176×84) for every other kind,
    /// unchanged. A ghost table uses this too — sized like a real one, drawn like a ghost.
    private var boxWidth: CGFloat { component.kind == .table ? CGFloat(BoardGeometry.size(of: component).x) : Self.width }
    private var boxHeight: CGFloat { component.kind == .table ? CGFloat(BoardGeometry.size(of: component).y) : Self.height }

    /// Kinds whose name is set inside the shape, centred, with a second centred line — the
    /// mockup draws these with `anchor="middle"` on both lines, unlike every left-aligned card.
    private static let centeredLabelKinds: Set<ComponentKind> = [.router, .register, .control]
    /// Kinds whose name is the only text, drawn in or under the shape itself rather than in a
    /// leading icon-and-text row.
    private static let embeddedNameKinds: Set<ComponentKind> = [
        .start, .end, .alu, .mux, .demux, .adder, .decoder, .clock, .bus,
    ]
    /// Kinds with no leading icon at all — their name and sub-line sit further left than the
    /// standard icon row leaves room for.
    private static let noIconKinds: Set<ComponentKind> = [.vectorStore, .memory, .ram]

    private var isGhost: Bool { component.outside != nil }
    private var isMissing: Bool { status == .missing && !component.planned && !isGhost }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shape
            if !isGhost {
                BoardShape.accents(for: component.kind)
            }
            content
                .padding(.leading, isGhost ? 14 : inset.leading)
                // A table's header and rows start flush at the top, exactly where
                // `BoardGeometry.rowCenterY` puts them, so foreign-key lines meet their rows; the
                // box is taller than its rows by the size formula's rounding and padding.
                .frame(width: boxWidth, height: boxHeight, alignment: isTableBox ? .topLeading : .leading)
                .offset(y: isGhost ? 0 : inset.verticalOffset)
        }
        .frame(width: boxWidth, height: boxHeight)
        .overlay(alignment: .topTrailing) {
            let dotInset = BoardShape.statusDotInset(for: component.kind)
            HStack(spacing: 4) {
                if component.detail != nil && !isGhost {
                    Text("↳")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                if status == .present {
                    Circle().fill(Theme.statusRunning).frame(width: 6, height: 6)
                }
            }
            .padding(.top, 7 + dotInset.top)
            .padding(.trailing, 7 + dotInset.right)
        }
        .overlay(alignment: .topLeading) {
            if isGhost && component.stale {
                Text("⚠")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.contextWarn)
                    .padding([.top, .leading], 6)
                    .help("No longer connected on the overview")
            }
        }
        .opacity(isMissing ? 0.5 : 1)
    }

    /// A database, cache, vector store or memory draws as two separate shapes, body then rim,
    /// exactly as the mockup paints them: a `<path>` for the body, then an `<ellipse>` on top for
    /// the rim — never one combined path, which is what made the rim read as a hole (opposite
    /// winding) with a stroked line across it (the body's own closing edge). Every other kind is
    /// one filled, stroked path, with its own fill and stroke colour where the mockup gives it
    /// one (a start pill's green tint, a bus's slate fill, and so on).
    @ViewBuilder
    private var shape: some View {
        switch component.kind {
        case .database, .cache, .vectorStore, .memory:
            BoardShape.cylinderBody.fill(fillColor(Theme.boardBox))
            BoardShape.cylinderBody.stroke(strokeColor, style: strokeStyle)
            BoardShape.cylinderRim.fill(fillColor(Theme.boardCylinderRim))
            BoardShape.cylinderRim.stroke(strokeColor, style: strokeStyle)
        case .table:
            // A plain rounded rect, sized to `boxWidth`/`boxHeight` by SwiftUI's own `Shape`
            // sizing (unlike `BoardShape.path(for:)`, whose paths are plotted in the fixed
            // 176×84 space and can't stretch) — never `BoardShape.path(for: .table)`, which this
            // case exists specifically so nothing ever calls.
            RoundedRectangle(cornerRadius: 8).fill(fillColor(Theme.boardBox))
            RoundedRectangle(cornerRadius: 8).stroke(strokeColor, style: strokeStyle)
        default:
            BoardShape.path(for: component.kind).fill(fillColor(BoardShape.fillColor(for: component.kind)))
            BoardShape.path(for: component.kind).stroke(strokeColor, style: strokeStyle)
        }
    }

    private func fillColor(_ solid: Color) -> Color { (component.planned || isGhost) ? Color.clear : solid }
    private var strokeStyle: StrokeStyle { StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: dash) }

    @ViewBuilder
    private var content: some View {
        if isGhost {
            Text(component.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        } else {
            switch component.kind {
            case _ where Self.centeredLabelKinds.contains(component.kind):
                centeredLabelContent
            case _ where Self.embeddedNameKinds.contains(component.kind):
                embeddedNameContent
            case _ where Self.noIconKinds.contains(component.kind):
                textStack
            case .table:
                tableRowsContent
            default:
                standardContent
            }
        }
    }

    /// The default row: a leading icon, the name, and its sub-line — every System kind, and the
    /// AI-agent kinds that keep that layout (agent, model, tool, mcp, prompt, state, human).
    private var standardContent: some View {
        HStack(spacing: 10) {
            icon
            nameAndSubLine(nameColor: Theme.textPrimary)
        }
    }

    /// A table's own content: a header with its name, then one row per column, at exactly the
    /// rows `BoardGeometry.rowCenterY(ofColumnAt:in:)` implies for this same box — a 36 pt header,
    /// then 22 pt per row, hairline separators between them. Never reached for a ghost table (see
    /// `content`'s `if isGhost` branch above, unchanged).
    /// A table drawn as its header and rows — not a ghost, which keeps the name-only ghost look.
    private var isTableBox: Bool {
        component.kind == .table && !isGhost
    }

    private var tableRowsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(component.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: boxWidth, height: 36, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.boardBoxStroke).frame(height: 1) }
            ForEach(Array(component.columns.enumerated()), id: \.offset) { index, column in
                tableRow(column)
                    .overlay(alignment: .bottom) {
                        if index < component.columns.count - 1 {
                            Rectangle().fill(Theme.boardBoxStroke).frame(height: 1)
                        }
                    }
            }
        }
    }

    /// One column's row: a key mark (a filled key for a primary key, a link for a foreign key, the
    /// same glyph at zero opacity — "a blank of the same width" — for neither), the name, and the
    /// type right-aligned and dimmed. A nullable column draws its whole row at 60% opacity; a
    /// planned column's name draws in `Theme.textTertiary` instead of `Theme.textPrimary` — the
    /// same faint colour a planned part's own outline already switches to (`strokeColor`, above).
    private func tableRow(_ column: BoardColumn) -> some View {
        HStack(spacing: 6) {
            Image(systemName: column.pk ? "key.fill" : "link")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 11, alignment: .center)
                .opacity(column.pk || column.references != nil ? 1 : 0)
            Text(column.name)
                .font(.system(size: 11.5))
                .foregroundStyle(column.planned ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(column.type)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(width: boxWidth, height: 22, alignment: .leading)
        .opacity(column.nullable ? 0.6 : 1)
    }

    /// The same name-and-sub-line column, without a leading icon — a vector store's dot grid and
    /// a memory's history glyph are accents on the shape itself, not a content-row icon; same for
    /// RAM's cell lines. Positioned by `inset`, exactly like `standardContent`.
    private var textStack: some View {
        nameAndSubLine(nameColor: Theme.textPrimary)
    }

    private func nameAndSubLine(nameColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(nameColor)
                .lineLimit(1)
            Text(subLine)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Router, register and control: the name and a second, smaller line, both centred in the
    /// shape — the mockup's only two-line labels drawn with `text-anchor="middle"`.
    private var centeredLabelContent: some View {
        VStack(spacing: 2) {
            Text(component.name)
                .font(.system(size: 13, weight: .semibold))
                .italic(component.kind == .control)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(subLine)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: Self.width, height: Self.height)
    }

    /// The kinds that carry only their own name, positioned exactly where the mockup places it —
    /// centred in the pill for start/end, centred in the trapezoid for a mux/demux (with "sel"
    /// captioned below), under the circle for an adder, under the small clock square beside its
    /// wave glyph, and above the bus bar. Several of these sit outside the component's own
    /// 176×84 box, on purpose, exactly as the mockup draws them — the canvas never clips a
    /// component's box, only its own viewport.
    ///
    /// The mockup's y's are SVG text baselines; `.position(y:)` instead centres the view. Each is
    /// converted here — centre ≈ baseline − 0.35 × the font size — so the name sits centred where
    /// the mockup draws it, not ~3.5 pt low.
    @ViewBuilder
    private var embeddedNameContent: some View {
        let cx = Self.width / 2
        ZStack {
            switch component.kind {
            case .start, .end:
                Text(component.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .position(x: cx, y: 42.45)
            case .alu:
                Text(component.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .position(x: cx + 6, y: 42.1)
            case .mux, .demux:
                Text(component.name).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .position(x: cx, y: 42.15)
                Text("sel").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .position(x: cx, y: 93.2)
            case .decoder:
                Text(component.name).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .position(x: cx, y: 42.15)
            case .adder:
                Text(component.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .position(x: cx, y: 92.85)
            case .clock:
                ClockWaveGlyph()
                Text(component.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .position(x: cx, y: 88.85)
            case .bus:
                Text(component.name).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    .position(x: cx, y: 26.5)
            default:
                EmptyView()
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var icon: some View {
        if let agent = BoardTech.agent(for: component) {
            AgentLogoView(agent: agent, size: 24)
        } else if let info = BoardTech.resolve(component) {
            TechLogoView(info: info, size: 24)
        } else if component.kind == .mcp {
            PlugGlyph().frame(width: 24, height: 24)
        } else {
            Image(systemName: component.kind.glyph)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
        }
    }

    /// The SF Symbol icon's tint — the mockup's own glyph colour for the AI-agent kinds it gives
    /// one (agent's sparkle, tool's wrench, prompt's document, state's brace, human's person; mcp
    /// draws `PlugGlyph` instead, already in its own colour); every other kind, System included,
    /// keeps the neutral `textSecondary` it always had.
    private var iconColor: Color {
        switch component.kind {
        case .agent: return Theme.boardAgentGlyph
        case .tool: return Theme.boardGlyphBlue
        case .prompt: return Theme.boardPromptGlyph
        case .state: return Theme.boardViolet
        case .human: return Theme.boardGold
        default: return Theme.textSecondary
        }
    }

    /// `KIND · <tech display name>`; else `KIND · <reachedBy>`, truncated; else the kind's own
    /// whole-line default (the new kinds' mockup label, such as "MCP SERVER" or "AGENT NODE");
    /// else, when that default is nil, the bare kind — which already matches the mockup for every
    /// kind whose default is just its own name (model, tool, router, memory, register).
    private var subLine: String {
        let kind = component.kind.raw.uppercased()
        if let agent = BoardTech.agent(for: component) { return "\(kind) · \(agent.displayName)" }
        if let info = BoardTech.resolve(component) { return "\(kind) · \(info.displayName)" }
        if let reachedBy = component.reachedBy, !reachedBy.isEmpty { return "\(kind) · \(reachedBy)" }
        return BoardShape.defaultSubLine(for: component.kind) ?? kind
    }

    /// Where the icon and text sit inside the kind's shape — leading inset and a small vertical
    /// nudge, both taken from the mockup's per-kind geometry. The centred and embedded-name kinds
    /// size their own content, so this is (0, 0) for them — the padding and offset below are then
    /// a no-op.
    private var inset: (leading: CGFloat, verticalOffset: CGFloat) {
        switch component.kind {
        case .database, .cache: return (14, 2)
        case .queue: return (16, 0)
        case .storage: return (18, 0)
        case .host: return (14, 0)
        case .external: return (26, 6)
        case .agent, .model: return (14, 0)
        case .tool: return (16, 0)
        case .mcp: return (24, 0)
        case .prompt: return (16, 0)
        case .state: return (14, 3)
        case .human: return (18, 0)
        case .vectorStore, .memory: return (16, 4)
        case .ram: return (36, -2)
        case _ where Self.centeredLabelKinds.contains(component.kind): return (0, 0)
        case _ where Self.embeddedNameKinds.contains(component.kind): return (0, 0)
        case .table: return (0, 0)
        default: return (14, 0)
        }
    }

    private var strokeColor: Color {
        if isSelected { return Theme.accent }
        if component.planned || isGhost { return Theme.textTertiary }
        return BoardShape.strokeColor(for: component.kind)
    }

    /// Planned draws dashed, as always; an external component draws dashed too — it lives outside
    /// the system — unless selected, when the accent outline takes over solid.
    private var dash: [CGFloat] {
        guard !isSelected else { return [] }
        return (component.planned || component.kind == .external || isGhost) ? [4, 3] : []
    }
}

/// The MCP kind's fallback glyph when no service logo resolves: a plug, translated from the
/// mockup's `GLYPHS["plug"]` (two prongs, a socket body, a short leg), in a 24×24 box.
private struct PlugGlyph: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 9, y: 3)); p.addLine(to: CGPoint(x: 9, y: 8))
            p.move(to: CGPoint(x: 15, y: 3)); p.addLine(to: CGPoint(x: 15, y: 8))
            p.move(to: CGPoint(x: 6, y: 8))
            p.addLine(to: CGPoint(x: 18, y: 8))
            p.addLine(to: CGPoint(x: 18, y: 11))
            p.addArc(center: CGPoint(x: 12, y: 11), radius: 6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
            p.move(to: CGPoint(x: 12, y: 17)); p.addLine(to: CGPoint(x: 12, y: 21))
        }
        .stroke(Theme.boardGreen, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }
}

/// The clock kind's glyph, centred in its small rounded square: a square/step wave (a clock
/// signal), translated from the mockup's `GLYPHS["clockwave"]` — not an SF Symbol, since
/// `waveform.path` reads as an audio waveform rather than a clock's square wave.
private struct ClockWaveGlyph: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 76.33, y: 48.67))
            p.addLine(to: CGPoint(x: 81, y: 48.67))
            p.addLine(to: CGPoint(x: 81, y: 39.33))
            p.addLine(to: CGPoint(x: 88, y: 39.33))
            p.addLine(to: CGPoint(x: 88, y: 48.67))
            p.addLine(to: CGPoint(x: 95, y: 48.67))
            p.addLine(to: CGPoint(x: 95, y: 39.33))
            p.addLine(to: CGPoint(x: 99.67, y: 39.33))
        }
        .stroke(Theme.boardClockGlyph, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
    }
}

/// The kind's shape, in the component box's own 176×84 space — translated from the approved
/// mockup's SVG generator (`ai()` and `hw()`). Every shape fits the same box so the layout grid
/// never has to know which kind it is placing.
enum BoardShape {
    private static let w = CGFloat(BoardGeometry.componentSize.x)
    private static let h = CGFloat(BoardGeometry.componentSize.y)

    private static let startFill = Color(red: 0.122, green: 0.227, blue: 0.173) // #1F3A2C
    private static let endFill = Color(red: 0.227, green: 0.141, blue: 0.141) // #3A2424
    private static let endStroke = Color(red: 0.851, green: 0.541, blue: 0.541) // #D98A8A
    private static let busFill = Color(red: 0.224, green: 0.259, blue: 0.310) // #39424F
    private static let ramLineColor = Color(red: 0.227, green: 0.227, blue: 0.275) // #3A3A46

    static func path(for kind: ComponentKind) -> Path {
        switch kind {
        case .database, .cache, .vectorStore, .memory: return cylinderBody
        case .queue: return pipe
        case .storage: return bucket
        case .host: return server
        case .external: return cloud
        case .agent: return agentCard
        case .model: return modelCard
        case .tool: return toolCard
        case .mcp: return mcpHexagon
        case .router: return routerDiamond
        case .start, .end: return pillCard
        case .prompt: return promptDoc
        case .state: return stateFolder
        case .human: return humanCapsule
        case .alu: return aluShape
        case .mux: return muxShape
        case .demux: return demuxShape
        case .register: return registerRect
        case .ram: return ramRect
        case .control: return controlEllipse
        case .adder: return adderCircle
        case .decoder: return decoderShape
        case .clock: return clockSquare
        case .bus: return busBar
        default: return card
        }
    }

    /// The shape's own fill, where the mockup gives it one other than the ordinary card fill
    /// (`Theme.boardBox`): a start pill's green tint, an end pill's red tint, a bus's slate fill.
    static func fillColor(for kind: ComponentKind) -> Color {
        switch kind {
        case .start: return startFill
        case .end: return endFill
        case .bus: return busFill
        default: return Theme.boardBox
        }
    }

    /// The shape's own outline colour, where the mockup gives it an accent (unselected, not
    /// planned) — everything else keeps the ordinary `Theme.boardBoxStroke`.
    static func strokeColor(for kind: ComponentKind) -> Color {
        switch kind {
        case .agent: return Theme.accent.opacity(0.55)
        case .mcp: return Theme.boardGreen.opacity(0.6)
        case .router: return Theme.boardGold.opacity(0.6)
        case .control: return Theme.boardGold.opacity(0.7)
        case .human: return Theme.boardGold.opacity(0.5)
        case .state: return Theme.boardViolet.opacity(0.5)
        case .start: return Theme.boardGreen
        case .end: return endStroke
        case .alu, .mux, .demux, .register, .ram, .adder, .decoder, .clock, .bus:
            return Theme.boardHardwareStroke
        default: return Theme.boardBoxStroke
        }
    }

    /// The whole-line default the new kinds show when a component has no tech and no
    /// reached-by — the mockup's own fixed label (e.g. "MCP SERVER", "AGENT NODE"), not
    /// `KIND · <default>`. `nil` falls back to the bare kind name, which already matches the
    /// mockup for every kind whose default is just its own name (model, tool, router, memory,
    /// register).
    static func defaultSubLine(for kind: ComponentKind) -> String? {
        switch kind {
        case .agent: return "AGENT NODE"
        case .mcp: return "MCP SERVER"
        case .vectorStore: return "VECTOR STORE"
        case .prompt: return "PROMPT · CONTEXT"
        case .human: return "HUMAN IN THE LOOP"
        case .ram: return "MEMORY"
        case .control: return "CONTROL UNIT"
        default: return nil
        }
    }

    /// How far a kind's drawn outline sits inside the fixed 176×84 box at the arrow's height
    /// (y = 42, the box's mid-height — every side port lands there), on the sides an arrow, a
    /// status dot, a side handle or the change glow might otherwise land past the shape: the
    /// bucket's taper (measured at that height, not its wider top), the cloud's left and right
    /// (it never reaches either side edge there — measured on the outline itself, not the widest
    /// point either lobe happens to reach at some other height), the pipe's top and bottom, the
    /// card's top and bottom, a diamond's or hexagon's vertices, a trapezoid's slanted sides, and
    /// so on for the new kinds — each measured the same way, on the rendered outline at that
    /// height (top/bottom at x = 88, left/right at y = 42). Zero elsewhere — those shapes already
    /// reach the box's edge on every side that matters.
    static func insets(for kind: ComponentKind) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .database, .cache, .vectorStore, .memory: return (0, 0, 0, 0)
        case .table: return (0, 0, 0, 0)
        case .queue: return (0, 0, 12, 12)
        case .storage: return (8, 8, 8, 8)
        case .host: return (0, 0, 0, 0)
        case .external: return (37, 15.5, 0, 0)
        case .agent, .model, .tool, .human: return (0, 0, 8, 8)
        case .mcp: return (0, 0, 4, 4)
        case .router: return (18, 18, 0, 0)
        case .start, .end: return (28, 28, 20, 20)
        case .prompt: return (6, 6, 6, 6)
        case .state: return (0, 0, 8, 0)
        case .alu: return (54, 40, 12, 12)
        case .mux, .demux: return (62, 62, 9, 9)
        case .register: return (20, 20, 6, 6)
        case .ram: return (26, 26, 0, 0)
        case .control: return (10, 10, 6, 6)
        case .adder: return (62, 62, 16, 16)
        case .decoder: return (50, 50, 8, 8)
        case .clock: return (58, 58, 20, 20)
        case .bus: return (0, 0, 35, 35)
        default: return (0, 0, 8, 8)
        }
    }

    /// Where the "present" status dot sits, padded in from the box's own top-right corner. Every
    /// straight-edged shape's `insets` value is the same at any height, so it places the dot
    /// correctly too — except shapes whose outline curves or angles sharply away from a
    /// rectangular corner (the cloud, the router's diamond, the control unit's ellipse, the
    /// decoder's and the clock's own outlines), measured separately here, on the outline itself
    /// near the top right, so the dot lands on it instead of floating past the shape.
    static func statusDotInset(for kind: ComponentKind) -> (top: CGFloat, right: CGFloat) {
        switch kind {
        case .external: return (36, 22)
        case .router: return (7, 58)
        case .control: return (13, 19)
        case .decoder: return (-4, 58)
        case .clock: return (13, 57)
        case .mcp: return (6, 6)
        default:
            let inset = insets(for: kind)
            return (inset.top, inset.right)
        }
    }

    /// The decoration that rides on top of the shape and never changes colour with state: a
    /// queue's chevrons, a host's rack lines, a cache's second, dashed rim, a model's dashed inner
    /// border, a vector store's dot grid, a memory's history glyph, a prompt's folded-corner
    /// crease, a register's clock notch and RAM's memory-cell lines.
    @ViewBuilder
    static func accents(for kind: ComponentKind) -> some View {
        switch kind {
        case .queue:
            ForEach(0..<3, id: \.self) { i in chevron(atX: w - 40 + CGFloat(i) * 8) }
        case .host:
            ForEach(0..<3, id: \.self) { i in rackLine(atY: 26 + CGFloat(i) * 15) }
        case .cache:
            cacheRim
        case .model:
            modelInnerBorder
        case .vectorStore:
            vectorDots
        case .memory:
            memoryHistoryGlyph
        case .prompt:
            promptFold
        case .register:
            registerNotch
        case .ram:
            ramLines
        case .adder:
            adderCross
        default:
            EmptyView()
        }
    }

    // MARK: - System shapes (unchanged)

    /// A cylinder's body: the side walls plus the bottom elliptical arc, left open along the top
    /// — exactly the mockup's path (`M x top L x bot A w/2 ry 0 0 0 x+w bot L x+w top`, never
    /// closed). Fill implicitly closes it along that top edge; stroke does not draw that edge, so
    /// no line crosses the rim. The rim itself is `cylinderRim`, a separate shape drawn on top.
    /// Also `vector-store`'s and `memory`'s shape — the same cylinder, with a dot grid or a
    /// history glyph as their accent instead of nothing.
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
        p.move(to: CGPoint(x: 52, y: 78))
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

    // MARK: - AI-agent shapes

    /// `agent`: the default card, at a wider 14 pt corner radius, with an accent outline.
    private static var agentCard: Path {
        Path(roundedRect: CGRect(x: 0, y: 8, width: w, height: h - 16), cornerRadius: 14)
    }

    /// `model`: a 10 pt-radius card; its dashed inner border is a separate accent.
    private static var modelCard: Path {
        Path(roundedRect: CGRect(x: 0, y: 8, width: w, height: h - 16), cornerRadius: 10)
    }

    /// `tool`: a card with all four corners clipped diagonally by 10 pt.
    private static var toolCard: Path {
        var p = Path()
        p.move(to: CGPoint(x: 10, y: 8))
        p.addLine(to: CGPoint(x: w - 10, y: 8))
        p.addLine(to: CGPoint(x: w, y: 18))
        p.addLine(to: CGPoint(x: w, y: h - 18))
        p.addLine(to: CGPoint(x: w - 10, y: h - 8))
        p.addLine(to: CGPoint(x: 10, y: h - 8))
        p.addLine(to: CGPoint(x: 0, y: h - 18))
        p.addLine(to: CGPoint(x: 0, y: 18))
        p.closeSubpath()
        return p
    }

    /// `mcp`: a hexagon, its two points sitting exactly on the box's left and right mid-edges.
    private static var mcpHexagon: Path {
        var p = Path()
        p.move(to: CGPoint(x: 18, y: 4))
        p.addLine(to: CGPoint(x: w - 18, y: 4))
        p.addLine(to: CGPoint(x: w, y: h / 2))
        p.addLine(to: CGPoint(x: w - 18, y: h - 4))
        p.addLine(to: CGPoint(x: 18, y: h - 4))
        p.addLine(to: CGPoint(x: 0, y: h / 2))
        p.closeSubpath()
        return p
    }

    /// `router`: a diamond, its side points on the mid-edges.
    private static var routerDiamond: Path {
        var p = Path()
        p.move(to: CGPoint(x: w / 2, y: 0))
        p.addLine(to: CGPoint(x: w - 18, y: h / 2))
        p.addLine(to: CGPoint(x: w / 2, y: h))
        p.addLine(to: CGPoint(x: 18, y: h / 2))
        p.closeSubpath()
        return p
    }

    /// `start`/`end`: a full stadium pill, tinted green or red in `fillColor(for:)`/`strokeColor(for:)`.
    private static var pillCard: Path {
        Path(roundedRect: CGRect(x: 28, y: 20, width: w - 56, height: h - 40), cornerRadius: (h - 40) / 2)
    }

    /// `prompt`: a document with its top-right corner folded down; the crease is a separate accent.
    private static var promptDoc: Path {
        var p = Path()
        p.move(to: CGPoint(x: 6, y: 6))
        p.addLine(to: CGPoint(x: w - 28, y: 6))
        p.addLine(to: CGPoint(x: w - 6, y: 28))
        p.addLine(to: CGPoint(x: w - 6, y: h - 6))
        p.addLine(to: CGPoint(x: 6, y: h - 6))
        p.closeSubpath()
        return p
    }

    /// `state`: a folder-tab card — a small notch cut into the top-left corner.
    private static var stateFolder: Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 18))
        p.addLine(to: CGPoint(x: 54, y: 18))
        p.addLine(to: CGPoint(x: 62, y: 8))
        p.addLine(to: CGPoint(x: w, y: 8))
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }

    /// `human`: a full stadium capsule, nearly the whole box.
    private static var humanCapsule: Path {
        Path(roundedRect: CGRect(x: 0, y: 8, width: w, height: h - 16), cornerRadius: 34)
    }

    private static var modelInnerBorder: some View {
        Path(roundedRect: CGRect(x: 4, y: 12, width: w - 8, height: h - 24), cornerRadius: 7)
            .stroke(Theme.boardBoxStroke, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    private static var vectorDots: some View {
        Path { p in
            for i in 0..<4 {
                for j in 0..<3 {
                    let cx = w - 40 + CGFloat(i) * 8
                    let cy = 36 + CGFloat(j) * 9
                    p.addEllipse(in: CGRect(x: cx - 1.8, y: cy - 1.8, width: 3.6, height: 3.6))
                }
            }
        }
        .fill(Theme.boardGlyphBlue)
    }

    /// A memory's history glyph: a near-full ring with a short hand, standing in for the mockup's
    /// clock-with-a-backward-arrow icon.
    private static var memoryHistoryGlyph: some View {
        ZStack {
            Path { p in p.addArc(center: CGPoint(x: w - 30, y: 46), radius: 8, startAngle: .degrees(-50), endAngle: .degrees(230), clockwise: false) }
                .stroke(Theme.boardGlyphBlue, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: w - 30, y: 42))
                p.addLine(to: CGPoint(x: w - 30, y: 46))
                p.addLine(to: CGPoint(x: w - 24, y: 46))
            }
            .stroke(Theme.boardGlyphBlue, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }

    private static var promptFold: some View {
        Path { p in
            p.move(to: CGPoint(x: w - 28, y: 6))
            p.addLine(to: CGPoint(x: w - 28, y: 28))
            p.addLine(to: CGPoint(x: w - 6, y: 28))
        }
        .stroke(Theme.boardBoxStroke, lineWidth: 1)
    }

    // MARK: - Hardware shapes

    /// `alu`: the classic notched ALU trapezoid — narrower on the right, with a V cut into the
    /// left edge at mid-height.
    private static var aluShape: Path {
        var p = Path()
        p.move(to: CGPoint(x: 40, y: 0))
        p.addLine(to: CGPoint(x: w - 40, y: 24))
        p.addLine(to: CGPoint(x: w - 40, y: h - 24))
        p.addLine(to: CGPoint(x: 40, y: h))
        p.addLine(to: CGPoint(x: 40, y: 52))
        p.addLine(to: CGPoint(x: 54, y: h / 2))
        p.addLine(to: CGPoint(x: 40, y: 32))
        p.closeSubpath()
        return p
    }

    /// `mux`: wide on the left (inputs), narrow on the right (the single output).
    private static var muxShape: Path {
        var p = Path()
        p.move(to: CGPoint(x: 62, y: 0))
        p.addLine(to: CGPoint(x: w - 62, y: 18))
        p.addLine(to: CGPoint(x: w - 62, y: h - 18))
        p.addLine(to: CGPoint(x: 62, y: h))
        p.closeSubpath()
        return p
    }

    /// `demux`: the mirror of `mux` — narrow input on the left, wide outputs on the right.
    private static var demuxShape: Path {
        var p = Path()
        p.move(to: CGPoint(x: 62, y: 18))
        p.addLine(to: CGPoint(x: w - 62, y: 0))
        p.addLine(to: CGPoint(x: w - 62, y: h))
        p.addLine(to: CGPoint(x: 62, y: h - 18))
        p.closeSubpath()
        return p
    }

    /// `register`: a plain rectangle; the clock notch on its bottom edge is a separate accent.
    private static var registerRect: Path {
        Path(CGRect(x: 20, y: 6, width: w - 40, height: h - 12))
    }

    /// `ram`: a tall rectangle spanning the full box height; its memory-cell lines are a separate accent.
    private static var ramRect: Path {
        Path(CGRect(x: 26, y: 0, width: w - 52, height: h))
    }

    /// `control`: an ellipse.
    private static var controlEllipse: Path {
        Path(ellipseIn: CGRect(x: 10, y: 6, width: w - 20, height: h - 12))
    }

    /// `adder`: a circle; the plus sign on it is a separate accent.
    private static var adderCircle: Path {
        Path(ellipseIn: CGRect(x: w / 2 - 26, y: h / 2 - 26, width: 52, height: 52))
    }

    /// `decoder`: the reverse of `mux` at a wider taper — narrow input on the left, wide outputs
    /// on the right, with no "sel" caption.
    private static var decoderShape: Path {
        var p = Path()
        p.move(to: CGPoint(x: 50, y: 16))
        p.addLine(to: CGPoint(x: w - 50, y: 0))
        p.addLine(to: CGPoint(x: w - 50, y: h))
        p.addLine(to: CGPoint(x: 50, y: h - 16))
        p.closeSubpath()
        return p
    }

    /// `clock`: a small rounded square, centred in the box, holding the wave glyph.
    private static var clockSquare: Path {
        Path(roundedRect: CGRect(x: w / 2 - 30, y: h / 2 - 22, width: 60, height: 44), cornerRadius: 6)
    }

    /// `bus`: a thick bar spanning the full width, centred vertically.
    private static var busBar: Path {
        Path(roundedRect: CGRect(x: 0, y: h / 2 - 7, width: w, height: 14), cornerRadius: 3)
    }

    private static var registerNotch: some View {
        Path { p in
            p.move(to: CGPoint(x: w / 2 - 8, y: h - 6))
            p.addLine(to: CGPoint(x: w / 2, y: h - 16))
            p.addLine(to: CGPoint(x: w / 2 + 8, y: h - 6))
        }
        .stroke(Theme.boardHardwareStroke, lineWidth: 1)
    }

    private static var ramLines: some View {
        Path { p in
            for i in 1...5 {
                let y = CGFloat(i) * 14
                p.move(to: CGPoint(x: w - 60, y: y))
                p.addLine(to: CGPoint(x: w - 26, y: y))
            }
        }
        .stroke(ramLineColor, lineWidth: 1)
    }

    private static var adderCross: some View {
        Path { p in
            p.move(to: CGPoint(x: w / 2 - 10, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 + 10, y: h / 2))
            p.move(to: CGPoint(x: w / 2, y: h / 2 - 10)); p.addLine(to: CGPoint(x: w / 2, y: h / 2 + 10))
        }
        .stroke(Theme.textPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
