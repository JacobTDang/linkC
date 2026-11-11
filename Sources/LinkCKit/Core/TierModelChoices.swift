import Foundation

/// The rules behind each Settings tier picker: which options to show, when "Other…" is selected,
/// and whether a typed OpenCode id is free. The view only renders this.
public struct TierModelChoices: Equatable, Sendable {
    public static let otherLabel = "Other…"

    /// Picker labels: available model ids, then "Other…".
    public let optionLabels: [String]
    /// The picker's current selection — a model id, or `otherLabel`.
    public let selectedOption: String
    /// Whether the typed-id text field should show.
    public let showsOtherField: Bool
    /// The current typed / configured id when Other is selected (or the id itself when listed).
    public let typedId: String
    /// Nil when the current value is acceptable; otherwise the refusal under the field.
    public let validationError: String?
    /// How old the agent's list is, e.g. "2m ago", or nil when never fetched.
    public let listAgeText: String?
    /// The last refresh error for this agent, if any.
    public let listError: String?

    public init(
        optionLabels: [String],
        selectedOption: String,
        showsOtherField: Bool,
        typedId: String,
        validationError: String?,
        listAgeText: String?,
        listError: String?
    ) {
        self.optionLabels = optionLabels
        self.selectedOption = selectedOption
        self.showsOtherField = showsOtherField
        self.typedId = typedId
        self.validationError = validationError
        self.listAgeText = listAgeText
        self.listError = listError
    }

    public static func make(
        agent: AgentKind,
        lists: [AgentKind: AgentModelList],
        settings: AgentModelSettings,
        current: String,
        now: Date = Date()
    ) -> TierModelChoices {
        let available = ModelListCache.available(for: agent, lists: lists, settings: settings)
            .filter { agent != .opencode || OpenCodeFreeModels.isFree($0.id) }
        let ids = available.map(\.id)
        var labels = ids
        labels.append(otherLabel)

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = ids.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        let selected = listed ? (ids.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed)
            : otherLabel

        let list = lists[agent]
        let age: String?
        if let fetchedAt = list?.fetchedAt {
            age = "\(AgeFormat.compact(from: fetchedAt, to: now)) ago"
        } else {
            age = nil
        }

        return TierModelChoices(
            optionLabels: labels,
            selectedOption: selected,
            showsOtherField: selected == otherLabel,
            typedId: trimmed,
            validationError: validationError(forTypedId: trimmed, agent: agent),
            listAgeText: age,
            listError: list?.error)
    }

    /// Nil when `id` may be set; otherwise the refusal text shown under the field.
    public static func validationError(forTypedId id: String, agent: AgentKind) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard agent == .opencode else { return nil }
        guard OpenCodeFreeModels.isFree(trimmed) else {
            return "\(trimmed) is not a free OpenCode model"
        }
        return nil
    }
}
