import SwiftUI
import LinkCKit

/// The prompt bar under a project's tab strip: type a task, see which agent, model and effort the router
/// picks for it, and Enter opens that session here. Tab picks the next agent that could take it and
/// Shift-Tab the previous one; Esc clears. ⌘K puts the cursor in the field.
struct PromptBarView: View {
    @Bindable var bar: PromptBar
    /// The project on screen, which the session opens in: the pick is read again when it changes.
    let project: String?
    /// Bumped by ⌘K; each change puts the cursor in the field.
    let focusRequest: Int

    var body: some View {
        PromptBarField(
            text: $bar.text, line: bar.line, isOpening: bar.isOpening, focusRequest: focusRequest,
            onSubmit: { bar.submit() }, onTab: { bar.cycleAgent(backward: $0) != nil }, onEscape: { bar.clear() })
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
    /// Moves the pick to the next agent, or the previous one for Shift-Tab; false when there is none
    /// to move to, and the key moves focus as usual.
    let onTab: (_ backward: Bool) -> Bool
    let onEscape: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    /// Whether the field had the keyboard when Enter started opening a pick.
    @State private var hadFocusWhenOpening = false

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
                    // Disabling a focused field ends its editing on macOS. Give the focus back once
                    // the pick is open or waits to be confirmed, so the second Enter lands in the field.
                    .onChange(of: isOpening) { wasOpening, opening in
                        if opening { hadFocusWhenOpening = focused } else if wasOpening, hadFocusWhenOpening { focused = true }
                    }
                    .onSubmit(onSubmit)
                    // Both reach the field before its editor moves focus. Shift-Tab arrives as backtab
                    // (U+0019), which `.tab` does not match.
                    .onKeyPress(.tab) { onTab(false) ? .handled : .ignored }
                    .onKeyPress(KeyEquivalent("\u{19}")) { onTab(true) ? .handled : .ignored }
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
            PromptBarPreviewLine(line: line, palette: .theme)
                .padding(.leading, 10)
        }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

extension PromptBarPreviewLine.Palette {
    /// The line in linkC's own colours.
    static let theme = PromptBarPreviewLine.Palette(
        quiet: Theme.textTertiary, secondary: Theme.textSecondary, error: Theme.statusError, accent: Theme.accent,
        agent: { Theme.agentColor($0) })
}
