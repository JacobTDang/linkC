import SwiftUI
import LinkCKit

/// The prompt bar under a project's tab strip: type a task, see which agent, model and effort the router
/// picks for it, and Enter opens that session here. Tab picks the next agent that could take it; Esc
/// clears. ⌘K puts the cursor in the field.
struct PromptBarView: View {
    @Bindable var bar: PromptBar
    /// The project on screen, which the session opens in: the pick is read again when it changes.
    let project: String?
    /// Bumped by ⌘K; each change puts the cursor in the field.
    let focusRequest: Int

    var body: some View {
        PromptBarField(
            text: $bar.text, line: bar.line, isOpening: bar.isOpening, focusRequest: focusRequest,
            onSubmit: { bar.submit() }, onTab: { bar.cycleAgent() != nil }, onEscape: { bar.clear() })
            .onChange(of: project) { _, _ in bar.projectChanged() }
    }
}

/// The field and its preview line, drawn from plain values so it can be looked at without the app.
struct PromptBarField: View {
    @Binding var text: String
    let line: PromptBarLine
    let isOpening: Bool
    let focusRequest: Int
    let onSubmit: () -> Void
    /// Moves the pick to the next agent; false when there is none to move to, and Tab moves focus as usual.
    let onTab: () -> Bool
    let onEscape: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(focused ? Theme.accent : Theme.textTertiary)
                TextField("Describe a task — linkC picks the agent", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .disabled(isOpening)
                    .onSubmit(onSubmit)
                    .onKeyPress(.tab) { onTab() ? .handled : .ignored }
                    // The first Esc clears the bar; one on an empty bar leaves it.
                    .onKeyPress(.escape) {
                        let wasEmpty = text.isEmpty
                        onEscape()
                        if wasEmpty { focused = false }
                        return .handled
                    }
                if text.isEmpty && !focused {
                    Text("⌘K")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.cardSurface(needsYou: false, hovering: focused || hovering))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { focused = true }
            .animation(Theme.hoverEase, value: focused || hovering)
            PreviewLine(line: line)
                .padding(.leading, 10)
        }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

/// One line under the field: the pick, why it cannot open, or that it is opening. Nothing while idle.
private struct PreviewLine: View {
    let line: PromptBarLine

    var body: some View {
        switch line {
        case .idle:
            EmptyView()
        case .pick(let pick):
            let arrow = Text(verbatim: "→ ").foregroundStyle(Theme.textTertiary)
            let agent = Text(verbatim: pick.agent.shortName)
                .foregroundStyle(Theme.agentColor(pick.agent))
                .fontWeight(.semibold)
            let model = Text(verbatim: " · \(pick.model)" + (pick.effort.map { " · \($0.rawValue)" } ?? ""))
                .foregroundStyle(Theme.textSecondary)
            let reason = Text(verbatim: " — \(pick.reason)").foregroundStyle(Theme.textTertiary)
            Text("\(arrow)\(agent)\(model)\(reason)")
                .modifier(LineStyle(help: pick.text))
        case .error(let message):
            // A refusal names each agent and why: it wraps rather than lose the specifics.
            Text(message)
                .foregroundStyle(Theme.statusError)
                .modifier(LineStyle(help: message, lines: 3))
        case .confirm(let pick):
            let prompt = Text(verbatim: "Enter again to open ").foregroundStyle(Theme.accent)
            let agent = Text(verbatim: pick.agent.shortName)
                .foregroundStyle(Theme.agentColor(pick.agent))
                .fontWeight(.semibold)
            let model = Text(verbatim: " · \(pick.model)" + (pick.effort.map { " · \($0.rawValue)" } ?? ""))
                .foregroundStyle(Theme.textSecondary)
            let reason = Text(verbatim: " — \(pick.reason)").foregroundStyle(Theme.textTertiary)
            Text("\(prompt)\(agent)\(model)\(reason)")
                .modifier(LineStyle(help: line.text))
        case .opening(let message), .opened(let message):
            Text(message)
                .foregroundStyle(Theme.textSecondary)
                .modifier(LineStyle(help: message))
        }
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
