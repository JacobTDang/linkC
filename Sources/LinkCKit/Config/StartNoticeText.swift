import Foundation

/// Joins start-up notices for the panel error bar. ErrorBar is single-line, so notices are
/// separated with a middle dot rather than a newline.
public enum StartNoticeText {
    public static let separator = " · "

    public static func joining(_ existing: String?, _ next: String) -> String {
        guard let existing, !existing.isEmpty else { return next }
        return existing + separator + next
    }
}
