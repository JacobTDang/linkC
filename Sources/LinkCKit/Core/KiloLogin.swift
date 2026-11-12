import Foundation

/// When Kilo is not connected, listing and launch fail. Those failures must say what to do:
/// run `kilo`, then `/connect` (spec 2026-11-12 §4.3).
public enum KiloLogin {
    public static let remedy = "run `kilo`, then `/connect`"

    /// Whether `text` looks like Kilo refusing because the account is not connected.
    public static func looksLikeMissingLogin(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "unauthorized",
            "not authenticated",
            "login required",
            "please log in",
            "please login",
            "sign in",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Appends the connect remedy when `text` looks like a missing login; otherwise returns `text`.
    public static func reporting(_ text: String) -> String {
        guard looksLikeMissingLogin(text) else { return text }
        if text.contains(remedy) { return text }
        return "\(text) — \(remedy)"
    }
}
