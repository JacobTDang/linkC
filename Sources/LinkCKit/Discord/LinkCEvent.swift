import Foundation

/// Something that happened in linkC that the user may want to hear about away from the Mac: what
/// linkC posts to Discord (spec 2026-11-05 §2). `project` is the canonical folder it belongs to,
/// nil for an event that belongs to no project (a watched service).
public struct LinkCEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// An agent finished, needs permission, is waiting for input, or ended with an error.
        case sessionState
        /// Any other alert linkC shows as a macOS notification.
        case alert
        /// A watched service went down or came back.
        case service
        /// A task became delivered, done, failed, expired or cancelled. Discord only.
        case task
        /// linkC closed a worker. Discord only.
        case workerClosed
    }

    /// How the event reads at a glance; it sets the color.
    public enum Tone: Equatable, Sendable {
        case done, needsYou, failed, info
    }

    public let kind: Kind
    public let tone: Tone
    public let title: String
    public let body: String
    public let project: String?
    public let at: Date

    public init(kind: Kind, tone: Tone, title: String, body: String, project: String?, at: Date) {
        self.kind = kind
        self.tone = tone
        self.title = title
        self.body = body
        self.project = project
        self.at = at
    }
}
