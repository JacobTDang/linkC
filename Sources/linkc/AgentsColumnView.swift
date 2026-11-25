import LinkCKit
import SwiftUI

/// The linkC agents column beside a terminal: the cards of the session's repo, as the linkc-agents mod
/// draws them inside the agent CLI. Drawn from an `AgentsColumn` alone; its clocks and ages redraw at
/// the moment their text changes.
struct AgentsColumnView: View {
    let column: AgentsColumn
    let onOpen: (String) -> Void

    var body: some View {
        TimelineView(AgentsColumnSchedule(column: column)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                if let problem = column.problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.statusError)
                        .lineLimit(3)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
                if !column.cards.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(column.cards) { card in
                                AgentCardRow(card: card, now: context.date) { onOpen(card.id) }
                            }
                        }
                    }
                } else if !column.isPending, column.problem == nil {
                    Text("No sessions in this repo.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: AgentsColumnLayout.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("linkC")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            Text("agents")
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 6)
            if let needsYou = column.needsYouLabel {
                Text(needsYou)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
                    .padding(.trailing, 4)
            }
            Text(column.countLabel)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// One card: a bar in the agent's tone, then two lines. The title, the model and the cache clock; the
/// state's glyph, what the session does or its state's words with its worktree, and its age. The
/// selected session's card holds the light a selected sidebar row does.
private struct AgentCardRow: View {
    let card: AgentCard
    let now: Date
    let onOpen: () -> Void

    @State private var hovering = false

    /// Needs you or at work: in full tone. At rest: dimmed.
    private var isActive: Bool { card.look.needsYou || card.look.isWorking }
    private var tone: Color { card.agentKind.map(Theme.agentColor) ?? Theme.textSecondary }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tone.opacity(isActive ? 1 : 0.45))
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    firstLine
                    secondLine
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(card.isSelected ? Color.white.opacity(0.09) : (hovering ? Theme.hover : Color.clear))
        )
        .onHover { hovering = $0 }
        .animation(Theme.hoverEase, value: hovering)
        .help("\(card.title) — \(card.detail)")
    }

    private var firstLine: some View {
        HStack(spacing: 5) {
            Text(card.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let cache = card.cache(at: now) {
                Text(cache.text)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(cache.tint.color)
                    .fixedSize()
            }
        }
    }

    private var secondLine: some View {
        HStack(spacing: 5) {
            Text(card.look.glyph)
                .font(.system(size: 8.5, weight: card.look.needsYou ? .heavy : .regular))
                .foregroundStyle(card.look.tint.color)
                .frame(width: 10)
            Text(card.summary)
                .font(.system(size: 11))
                .foregroundStyle(card.look.needsYou ? card.look.tint.color : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .smoothShimmer(isWorking: card.isWorking)
            // Set apart from what the session does, and never truncated away by it.
            if !card.worktree.isEmpty {
                Text(card.worktree)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            Text(card.age(at: now))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }
}

private extension AgentCardLook.Tint {
    var color: Color {
        switch self {
        case .attention: return Theme.accent
        case .error: return Theme.statusError
        case .working: return Theme.statusWorking
        case .done: return Theme.statusRunning
        case .muted: return Theme.textTertiary
        }
    }
}

private extension AgentCacheLabel.Tint {
    var color: Color {
        switch self {
        case .muted: return Theme.textTertiary
        case .soon: return Theme.contextWarn
        case .cold: return Theme.statusError
        }
    }
}

/// Redraws the column when the start date comes, then each time a card's age or cache clock next reads
/// differently: nothing ticks on a column with no clock to change.
private struct AgentsColumnSchedule: TimelineSchedule {
    let column: AgentsColumn

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(column: column, current: startDate, isFirst: true)
    }

    struct Entries: Sequence, IteratorProtocol {
        let column: AgentsColumn
        var current: Date
        var isFirst: Bool

        mutating func next() -> Date? {
            if isFirst {
                isFirst = false
                return current
            }
            guard let next = column.nextRedraw(after: current) else { return nil }
            current = next
            return next
        }
    }
}
