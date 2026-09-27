import Foundation

/// How long a detected usage limit really lasts, computed fresh whenever one is recorded.
///
/// `LimitMatch.cooldown` (15 minutes for most agents) is a fixed guess. linkC already reads an
/// agent's real usage windows (`AgentUsage`, in `Sources/LinkCKit/Usage/`) and the banner itself
/// often states its own reset — either is a far better answer than a flat window that can expire
/// hours before a real 5-hour reset, or (more rarely) outlast a short one.
public enum LimitCooldown {
    /// At or past this, a usage window counts as exhausted — matches how close to 100% a
    /// provider's own reporting tends to sit right when it starts refusing requests.
    private static let exhaustedThreshold: Double = 99.5

    /// No computed expiry may sit closer to `now` than this: a limit that "clears" immediately
    /// would just have `checkLimitsAndReroute` re-detect the same banner on the very next tick.
    private static let minimumRest: TimeInterval = 60

    /// When a usage-limit banner should stop rerouting `agent`'s work. The first rule that
    /// applies wins:
    ///
    /// 1. A usage window at or past `exhaustedThreshold` with a `resetsAt` still in the future:
    ///    the EARLIEST such reset. This beats everything else — linkC already knows the
    ///    provider's own window state, rather than guessing from banner text.
    /// 2. The banner text states when it clears: an absolute local time ("try again at 3:05 PM",
    ///    or bare "3:05pm" — the next occurrence of that time after `now`) or a relative duration
    ///    ("try again in 2h 10m", "in 45 minutes", "in 1 hour" — `now` plus that duration).
    /// 3. `now + fallback` — the banner's own fixed cooldown, unchanged from today's behavior.
    ///
    /// Whatever rule fires, the result is never less than `now + 60s`.
    public static func expiry(
        bannerText: String,
        usage: AgentUsage?,
        now: Date,
        calendar: Calendar,
        fallback: TimeInterval
    ) -> Date {
        let floor = now.addingTimeInterval(minimumRest)
        if let fromUsage = earliestExhaustedReset(in: usage, now: now) {
            return max(fromUsage, floor)
        }
        if let fromBanner = parseBannerTime(bannerText, now: now, calendar: calendar) {
            return max(fromBanner, floor)
        }
        return max(now.addingTimeInterval(fallback), floor)
    }

    /// True when rule 1 or 2 above would drive `expiry` — real evidence (a usage window's own
    /// reset, or a time the banner itself states), not merely the fixed fallback recomputed
    /// against a later `now`. Recomputing the SAME fallback duration on every tick would always
    /// look "later" than a cooldown that is actually ticking down, which is exactly the
    /// re-arm-on-every-tick bug `recordLimit` already guards against — so a caller deciding
    /// whether to push an already-live cooldown out further (`InboxStore.extendLimit`) must act
    /// only on this, never on the fallback alone.
    public static func hasConfidentSignal(bannerText: String, usage: AgentUsage?, now: Date, calendar: Calendar) -> Bool {
        earliestExhaustedReset(in: usage, now: now) != nil || parseBannerTime(bannerText, now: now, calendar: calendar) != nil
    }

    // MARK: - Rule 1: usage windows

    /// The earliest `resetsAt` among windows at or past `exhaustedThreshold` whose reset has not
    /// already happened. A window whose reset is in the past describes a window that has already
    /// moved on — reading it as "still exhausted until then" would be reading stale state.
    private static func earliestExhaustedReset(in usage: AgentUsage?, now: Date) -> Date? {
        guard let usage else { return nil }
        return usage.windows
            .compactMap { window -> Date? in
                guard let usedPercent = window.usedPercent, usedPercent >= exhaustedThreshold else { return nil }
                guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
                return resetsAt
            }
            .min()
    }

    // MARK: - Rule 2: banner text

    /// Combined "in 2h 10m" — both parts mandatory so a bare "in" (as in "logged in") never
    /// matches.
    private static let hoursAndMinutesRegex = try! NSRegularExpression(
        pattern: "\\bin\\s+(\\d+)\\s*h(?:ours?)?\\s*(\\d+)\\s*m(?:in(?:utes?)?)?\\b",
        options: [.caseInsensitive]
    )
    /// "in 1 hour" — hours only.
    private static let hoursOnlyRegex = try! NSRegularExpression(
        pattern: "\\bin\\s+(\\d+)\\s*h(?:ours?)?\\b",
        options: [.caseInsensitive]
    )
    /// "in 45 minutes" — minutes only.
    private static let minutesOnlyRegex = try! NSRegularExpression(
        pattern: "\\bin\\s+(\\d+)\\s*m(?:in(?:utes?)?)?\\b",
        options: [.caseInsensitive]
    )
    /// "3:05 PM" / "3:05pm", with or without a leading "at" — the leading word is not captured,
    /// so this matches equally inside "try again at 3:05 PM." and a bare "3:05pm".
    private static let atTimeRegex = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2}):(\\d{2})\\s*([APap])\\.?[Mm]\\.?\\b",
        options: []
    )

    private static func parseBannerTime(_ text: String, now: Date, calendar: Calendar) -> Date? {
        if let duration = parseDuration(text) {
            return now.addingTimeInterval(duration)
        }
        return parseAtTime(text, now: now, calendar: calendar)
    }

    /// Tried most-specific first: a bare "in 2h 10m" would also satisfy the hours-only pattern
    /// (matching just the "2h" and stopping), so the combined form must be checked before it.
    private static func parseDuration(_ text: String) -> TimeInterval? {
        if let groups = firstMatch(hoursAndMinutesRegex, in: text, groups: 2),
           let hours = Int(groups[0]), let minutes = Int(groups[1]) {
            return TimeInterval(hours * 3600 + minutes * 60)
        }
        if let groups = firstMatch(hoursOnlyRegex, in: text, groups: 1), let hours = Int(groups[0]) {
            return TimeInterval(hours * 3600)
        }
        if let groups = firstMatch(minutesOnlyRegex, in: text, groups: 1), let minutes = Int(groups[0]) {
            return TimeInterval(minutes * 60)
        }
        return nil
    }

    private static func parseAtTime(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let groups = firstMatch(atTimeRegex, in: text, groups: 3),
              var hour = Int(groups[0]), let minute = Int(groups[1]),
              hour >= 1, hour <= 12, minute >= 0, minute < 60
        else { return nil }

        let isPM = groups[2].lowercased() == "p"
        if isPM, hour != 12 { hour += 12 }
        if !isPM, hour == 12 { hour = 0 }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        // The time has already happened today — a banner never means "yesterday", so it must
        // mean the next occurrence, tomorrow.
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// The first match's capture groups, as plain strings. Returns nil unless every one of the
    /// first `groups` capture groups is present — every regex above is written so its groups are
    /// all mandatory, never optional, precisely so a partial match here can't happen.
    private static func firstMatch(_ regex: NSRegularExpression, in text: String, groups: Int) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var values: [String] = []
        for index in 1...groups {
            guard let matchRange = Range(result.range(at: index), in: text) else { return nil }
            values.append(String(text[matchRange]))
        }
        return values
    }
}
