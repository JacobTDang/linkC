import Foundation

/// An app tab that is open in a project: the app's folder and the name its tab shows. Saved with
/// the sidebar state, so the tab comes back (asleep) after linkC restarts.
public struct OpenApp: Codable, Equatable, Sendable {
    public let folder: String
    public let name: String

    public init(folder: String, name: String) {
        self.folder = (folder as NSString).standardizingPath
        self.name = name
    }
}
