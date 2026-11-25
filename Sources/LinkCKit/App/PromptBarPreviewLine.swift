import SwiftUI

/// The line under the prompt bar: the pick, a pick waiting for a second Enter, why the task cannot
/// open, or that it is opening or opened. It is always one line high, empty while idle, so the
/// terminal below never resizes as the user types; the tooltip holds what a long line cuts off.
/// Drawn from the app's colours.
public struct PromptBarPreviewLine: View {
    /// One line of the line's 11 pt text.
    public static let height: CGFloat = 14

    /// The colours the line draws in.
    public struct Palette: Sendable {
        /// The arrow and the reason.
        public let quiet: Color
        /// The model and effort, and a session opening or opened.
        public let secondary: Color
        public let error: Color
        /// "Enter again to open".
        public let accent: Color
        public let agent: @Sendable (AgentKind) -> Color

        public init(
            quiet: Color, secondary: Color, error: Color, accent: Color, agent: @escaping @Sendable (AgentKind) -> Color
        ) {
            self.quiet = quiet
            self.secondary = secondary
            self.error = error
            self.accent = accent
            self.agent = agent
        }
    }

    let line: PromptBarLine
    let palette: Palette

    public init(line: PromptBarLine, palette: Palette) {
        self.line = line
        self.palette = palette
    }

    public var body: some View {
        content
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .help(line.text)
    }

    @ViewBuilder private var content: some View {
        switch line {
        case .idle:
            Color.clear
        case .pick(let pick):
            pickText(pick, lead: Text(verbatim: "→ ").foregroundStyle(palette.quiet))
        case .confirm(let pick):
            pickText(pick, lead: Text(verbatim: "Enter again to open ").foregroundStyle(palette.accent))
        case .error(let message):
            Text(message).foregroundStyle(palette.error)
        case .opening(let message), .opened(let message):
            Text(message).foregroundStyle(palette.secondary)
        }
    }

    private func pickText(_ pick: PromptBarPick, lead: Text) -> Text {
        let agent = Text(verbatim: pick.agent.shortName)
            .foregroundStyle(palette.agent(pick.agent))
            .fontWeight(.semibold)
        let model = Text(verbatim: " · \(pick.model)" + (pick.effort.map { " · \($0.rawValue)" } ?? ""))
            .foregroundStyle(palette.secondary)
        let reason = Text(verbatim: " — \(pick.reason)").foregroundStyle(palette.quiet)
        return Text("\(lead)\(agent)\(model)\(reason)")
    }
}
