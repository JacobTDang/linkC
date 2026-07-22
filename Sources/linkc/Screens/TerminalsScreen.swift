import SwiftUI
import AppKit
import LinkCKit

/// The Terminals screen — every dev terminal, running or exited, with the New Terminal
/// entry point. Same live-preview cadence as home.
struct TerminalsScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Terminals")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                ChromeButton(systemName: "plus", help: "New terminal") {
                    model.newShellTerminal()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if model.shellRows.isEmpty {
                VStack(spacing: 8) {
                    Text("No terminals yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("A plain shell in any folder — run your dev servers beside your sessions.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                    QuietLink("New terminal") { model.newShellTerminal() }
                        .padding(.top, 2)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        VStack(spacing: 6) {
                            ForEach(model.shellRows) { row in
                                TerminalCard(
                                    row: row,
                                    preview: model.recentOutput(row.id, lines: 3),
                                    onOpen: { model.focus(row.id) },
                                    onStop: { model.stopShell(row.id) },
                                    onRelaunch: { model.relaunchShell(row) },
                                    onDismiss: { model.dismissShell(row.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

/// One dev terminal card, shared by the home section and the Terminals screen. Quieter than
/// a session card: a small steady dot (no pulse, no glow — urgency is claude's vocabulary),
/// the folder title and path, a live preview. Running shows a hover-revealed stop ✕; exited
/// dims the card, keeps it tappable (scrollback stays inspectable), and offers Relaunch +
/// dismiss.
struct TerminalCard: View {
    let row: ShellRow
    let preview: String
    let onOpen: () -> Void
    let onStop: () -> Void
    let onRelaunch: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    private var isRunning: Bool { row.state == .running }

    private var dotColor: Color {
        switch row.state {
        case .running: return Theme.textSecondary
        case .exited(let code): return code == 0 ? Theme.textTertiary : Theme.statusError
        }
    }

    private var exitLabel: String? {
        guard case .exited(let code) = row.state else { return nil }
        return code == 0 ? "closed" : "exited"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 18, height: 18)  // StatusDot's box, minus its glow
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((row.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)

                if let exitLabel {
                    Text(exitLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(dotColor)
                        .fixedSize()
                    Button(action: onRelaunch) {
                        Text("Relaunch")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open a fresh shell in this folder")
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                } else {
                    Button(action: onStop) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .help("Stop terminal")
                }
            }
            PreviewText(text: preview)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(Theme.cardSurface(needsYou: false, hovering: hovering && isRunning))
        )
        .opacity(isRunning ? 1 : 0.75)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help(isRunning ? "Open \(row.title)" : "View \(row.title)'s last output")
    }
}
