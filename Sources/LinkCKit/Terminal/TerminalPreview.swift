import Foundation

/// Turns raw terminal rows into home-card preview content. A Claude session's last rows are
/// usually its input-box furniture — box-drawing frames, horizontal rules, a bare prompt
/// marker — which read as noise in a 3-line preview. Rows are kept or dropped whole (kept
/// rows keep their original text); only chrome-only rows and blanks are removed.
public enum TerminalPreview {
    /// The last `lines` content rows, joined with newlines. "" when nothing qualifies.
    public static func excerpt(rows: [String], lines: Int) -> String {
        rows.filter(hasContent).suffix(lines).joined(separator: "\n")
    }

    /// A row has content when something remains after removing box-drawing/block glyphs and
    /// trimming whitespace — and that remainder is more than a bare prompt marker or one of
    /// Claude Code's status-bar banners.
    static func hasContent(_ row: String) -> Bool {
        let stripped = row.unicodeScalars.filter { !isBoxDrawing($0) }
        let text = String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        return !barePrompts.contains(text) && !isStatusFurniture(text)
    }

    /// Claude Code's status-bar banners — text-only chrome that sits by the input box and would
    /// otherwise dominate a 3-line preview. Patterns stay anchored so real output that carries
    /// a ⚠ or mentions MCP is never eaten.
    private static func isStatusFurniture(_ text: String) -> Bool {
        // Trailing hints are the strip's signature: the permission-mode line always ends with
        // "(shift+tab to cycle)", the spinner row with "esc to interrupt)".
        if text.hasSuffix("(shift+tab to cycle)") || text.hasSuffix("esc to interrupt)") {
            return true
        }
        if text == "? for shortcuts" { return true }

        // Banner rows, matched after any leading warning/failure glyph.
        var t = text
        if let first = t.first, "⚠✗✘".contains(first) {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let bannerPrefixes = [
            "Transcript saving is off",
            "Context left until auto-compact:",
            "Context low (",
            "Auto-update failed",
            "Press up to edit queued messages",
        ]
        if bannerPrefixes.contains(where: t.hasPrefix) { return true }
        // The spinner row carries its token counter ("Boondoggling… (50s · ↓2.5k tokens …")
        // even when a narrow pane cuts off the "esc to interrupt" hint that usually marks it.
        if t.range(of: #"… \(\d+[hms][\dhms ]*·\s*[↑↓]"#, options: .regularExpression) != nil {
            return true
        }
        return t.range(
            of: #"^(\d+ MCP servers? needs? authentication|Approaching [\w ]{0,24}usage limit|You've used \d+% of your session limit)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// Box Drawing (U+2500–U+257F) and Block Elements (U+2580–U+259F).
    private static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    /// A prompt marker alone on its row promises input, not output — chrome either way.
    public static let barePrompts: Set<String> = ["❯", ">", "$", "›", "%", "?", "»", "→"]

    /// Checks if a line is an interactive input prompt awaiting user submission.
    public static func isPromptRow(_ text: String) -> Bool {
        if barePrompts.contains(text) { return true }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if barePrompts.contains(trimmed) { return true }
        if trimmed == "codex >" || trimmed == "agy >" || trimmed == "cursor >" { return true }
        if trimmed.hasPrefix("› Ask Codex") || trimmed.contains("Ask Codex to do anything") { return true }
        if trimmed.hasPrefix("❯ ") && trimmed.count <= 3 { return true }
        if trimmed.hasPrefix("› ") && trimmed.count <= 3 { return true }
        if trimmed.hasPrefix("> ") && trimmed.count <= 3 { return true }
        if (trimmed.hasPrefix("→") || trimmed.hasPrefix("->")) && !trimmed.contains("ctrl+c to stop") {
            if trimmed.count <= 3 || trimmed.contains("Plan, search, build anything") || trimmed.contains("Add a follow-up") {
                return true
            }
        }
        return false
    }

    /// Scans recent rows from the bottom up for a turn in progress and its phrase. An agent keeps
    /// its input box on screen while it works, so the box alone says nothing: a working marker in
    /// the footer below it is what says the turn is running, and the phrase is the spinner row
    /// above the box. Without that marker the box ends the scan, because everything above it may
    /// be a finished turn's output.
    public static func liveActivity(from rows: [String]) -> String? {
        let recent = Array(rows.suffix(12).reversed())
        var footerSaysWorking = false
        for (index, row) in recent.enumerated() {
            let text = visibleText(row)
            guard !text.isEmpty else { continue }
            if isWorkingFooter(text) {
                footerSaysWorking = true
                continue
            }
            guard !text.hasSuffix("(shift+tab to cycle)") && text != "? for shortcuts" else { continue }

            if isPromptRow(text) {
                let above = recent[(index + 1)...].lazy.map { visibleText($0) }.filter { !$0.isEmpty }
                if footerSaysWorking {
                    return above.compactMap { spinnerPhrase($0) }.first ?? "Working"
                }
                // Codex has no working footer: its status row ("• Working (9s • esc to interrupt)")
                // sits right above the input box, and is gone once the turn ends.
                if let status = above.first, status.contains("esc to interrupt)") {
                    let unbulleted = status.hasPrefix("•") ? String(status.dropFirst()).trimmingCharacters(in: .whitespaces) : status
                    return spinnerPhrase(unbulleted) ?? "Working"
                }
                return nil
            }

            var bannerCandidate = text
            if let first = bannerCandidate.first, "⚠✗✘".contains(first) {
                bannerCandidate = String(bannerCandidate.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let bannerPrefixes = [
                "Transcript saving is off",
                "Context left until auto-compact",
                "Context low",
                "Auto-update failed",
                "Press up to edit queued messages",
            ]
            if bannerPrefixes.contains(where: bannerCandidate.hasPrefix) {
                continue
            }

            if let phrase = spinnerPhrase(text) { return phrase }
            let cleaned = cleanLeadingSpinner(text)

            // Standalone action line ending in ellipsis or starting with an action verb
            let actionPrefixes = [
                "Thinking", "Generating", "Working", "Running", "Writing",
                "Reading", "Editing", "Searching", "Building", "Compiling",
                "Fetching", "Indexing", "Analyzing", "Checking", "Testing"
            ]
            if actionPrefixes.contains(where: { cleaned.hasPrefix($0) }) {
                if let parenIndex = cleaned.firstIndex(of: "(") {
                    let extracted = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                    if !extracted.isEmpty { return extracted }
                }
                if let doubleSpace = cleaned.range(of: "  ") {
                    let extracted = String(cleaned[..<doubleSpace.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !extracted.isEmpty { return extracted }
                }
                return cleaned
            }
            if (cleaned.hasSuffix("…") || cleaned.hasSuffix("...")) && !cleaned.isEmpty {
                return cleaned
            }
        }
        return footerSaysWorking ? "Working" : nil
    }

    /// Whether the screen is Codex's or Antigravity's folder-trust dialog: its question row, then
    /// its "yes" choice at the bottom of the screen. A question quoted in ordinary output has no
    /// choice under it, and a dialog left above a redrawn session has been answered.
    public static func isTrustPrompt(_ rows: [String]) -> Bool {
        let texts = rows.map { $0.trimmingCharacters(in: .whitespaces) }
        // Only the opening words: a narrow panel wraps the rest of the question onto other rows.
        guard let question = texts.lastIndex(where: { $0.hasPrefix("Do you trust the contents") }),
              let choice = texts[(question + 1)...].firstIndex(where: {
                  $0.contains("Yes, continue") || $0.contains("Yes, I trust this folder")
              })
        else { return false }
        // The dialog owns the bottom of the screen: Codex draws two rows under its choice and
        // Antigravity three, none of them an input box. A live session printing the dialog's text
        // has its own input box under it.
        let below = texts[(choice + 1)...]
        return below.count <= 3 && !below.contains(where: isPromptRow)
    }

    /// Whether a row redraws on its own while a turn runs — a working footer, a spinner row with a
    /// timer or token counter, or an animated Braille spinner. A screen signature leaves these
    /// out, so a ticking timer never looks like progress. A row led by a static glyph (Codex's
    /// "•", Claude Code's "⏺", Antigravity's "●") is ordinary output and counts. An elapsed-time
    /// counter trailing an otherwise-new row ("· 9s", "(12.4s)") is NOT filtered here — that
    /// swallowed one-shot output like "Ran 24 tests (12.4s)" too. `progressSignature` handles
    /// ticking counters instead, by normalizing time values.
    public static func isLiveMarkerRow(_ row: String) -> Bool {
        let text = visibleText(row)
        guard !text.isEmpty else { return false }
        if isWorkingFooter(text) { return true }
        if text.contains("esc to interrupt") { return true }
        if text.range(of: #"… \(\d+[hms][\dhms ]*·\s*[↑↓]"#, options: .regularExpression) != nil { return true }
        return text.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
    }

    /// A signature of `rows` for detecting a turn that has stopped producing anything new. Rows
    /// that redraw on their own are dropped, and time values are normalized so a ticking clock
    /// ("· 9s" a second after "· 8s") reads as unchanged — but any other change, including a
    /// percentage, byte count, or tally, does not. Known limit: a number that carries a time unit
    /// is treated as a clock, so a row whose only change is an ETA counting down or a size written
    /// with an "m" suffix reads as unchanged.
    public static func progressSignature(rows: [String]) -> String {
        let kept = rows
            .filter { !isLiveMarkerRow($0) }
            .map { $0.replacingOccurrences(of: #"\d+(\.\d+)?\s?(ms|s|m|h)\b"#, with: "#", options: .regularExpression) }
        return String(kept.joined(separator: "\n").hashValue)
    }

    /// The phrase on a live spinner row: one carrying "(12s · esc to interrupt)" or a token
    /// counter, or one led by a spinner glyph (Braille included). nil for any other row.
    private static func spinnerPhrase(_ text: String) -> String? {
        let cleaned = cleanLeadingSpinner(text)
        if text.contains("esc to interrupt") || text.range(of: #"… \(\d+[hms][\dhms ]*·\s*[↑↓]"#, options: .regularExpression) != nil {
            if let parenIndex = cleaned.firstIndex(of: "(") {
                let extracted = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                if !extracted.isEmpty { return extracted }
            }
            if !cleaned.isEmpty { return cleaned }
        }
        guard cleaned != text, !cleaned.isEmpty else { return nil }
        if let parenIndex = cleaned.firstIndex(of: "(") {
            let extracted = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespaces)
            if !extracted.isEmpty { return extracted }
        }
        if let doubleSpace = cleaned.range(of: "  ") {
            let extracted = String(cleaned[..<doubleSpace.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !extracted.isEmpty { return extracted }
        }
        return cleaned
    }

    /// A footer that only shows while a turn runs: Claude Code's "· esc to interrupt ·" (its
    /// spinner row instead ends "esc to interrupt)") or Antigravity's "esc to cancel".
    private static func isWorkingFooter(_ text: String) -> Bool {
        if text.hasPrefix("esc to cancel") { return true }
        return text.contains("esc to interrupt") && !text.contains("esc to interrupt)")
    }

    /// A row with box-drawing and block glyphs removed and surrounding whitespace trimmed.
    private static func visibleText(_ row: String) -> String {
        let stripped = row.unicodeScalars.filter { !isBoxDrawing($0) }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespaces)
    }

    private static func cleanLeadingSpinner(_ text: String) -> String {
        var t = text
        let spinnerChars: Set<Character> = [
            "✻", "✳", "*", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
            "●", "○", "◐", "◑", "◒", "◓", "✦", "✧", "✨", "-", "|", "/", "\\"
        ]
        while let first = t.first {
            let isBraille = first.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
            if isBraille || spinnerChars.contains(first) || first.isWhitespace {
                t.removeFirst()
            } else {
                break
            }
        }
        return t
    }
}
