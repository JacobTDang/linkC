import SwiftUI

/// The line under the prompt bar: the pick, a pick waiting for a second Enter, why the task cannot
/// open, or that it is opening or opened. Nothing while idle. Drawn from the app's colours.
public struct PromptBarPreviewLine: View {
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
        switch line {
        case .idle:
            EmptyView()
        case .pick(let pick):
            pickText(pick, lead: Text(verbatim: "→ ").foregroundStyle(palette.quiet))
                .modifier(LineStyle(help: pick.text))
        case .confirm(let pick):
            pickText(pick, lead: Text(verbatim: "Enter again to open ").foregroundStyle(palette.accent))
                .modifier(LineStyle(help: line.text))
        case .error(let message):
            // A refusal names each agent and why: it wraps rather than lose the specifics.
            Text(message)
                .foregroundStyle(palette.error)
                .modifier(LineStyle(help: message, lines: 3))
        case .opening(let message), .opened(let message):
            Text(message)
                .foregroundStyle(palette.secondary)
                .modifier(LineStyle(help: message))
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

private struct LineStyle: ViewModifier {
    let help: String
    var lines = 1

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11))
            .lineLimit(lines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .help(help)
    }
}
