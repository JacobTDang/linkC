import Foundation

/// Decodes a hook request (our `X-LinkC-*` headers + Claude's JSON body) into a HookEvent.
///
/// The event `kind` is authoritative from our own `X-LinkC-Event` header — never inferred
/// from Claude's body — so decoding never depends on the shape of Claude's payload beyond
/// the two fields we actually use. Real payloads carry many other fields (`permission_mode`,
/// `prompt_id`, `transcript_path`, ...); `HookBody` only declares what we read, and
/// `JSONDecoder` simply ignores the rest.
public enum HookEventDecoder {
    /// Returns nil if the event kind is unknown (or the header is missing). Header lookup
    /// is case-insensitive. A malformed/unexpected body never fails decoding outright —
    /// only the event kind (from our header) is required; `claudeSessionId`/`cwd` are
    /// simply nil when the body can't be parsed.
    public static func decode(headers: [String: String], body: Data) -> HookEvent? {
        guard
            let rawKind = header(named: "X-LinkC-Event", in: headers),
            let kind = HookEventKind(rawValue: rawKind)
        else {
            return nil
        }

        let linkcSessionId = header(named: "X-LinkC-Session", in: headers)
        let parsedBody = try? JSONDecoder().decode(HookBody.self, from: body)

        return HookEvent(
            kind: kind,
            linkcSessionId: linkcSessionId,
            claudeSessionId: parsedBody?.sessionId,
            cwd: parsedBody?.cwd,
            receivedAt: Date()
        )
    }

    /// Case-insensitive header lookup — HTTP header names aren't case-stable, and
    /// `NWConnection`-parsed requests preserve whatever casing the client sent.
    private static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The subset of Claude's hook JSON body we care about. Every other real key
/// (`hook_event_name`, `permission_mode`, `prompt_id`, `transcript_path`, ...) is ignored by the decoder.
private struct HookBody: Decodable {
    let sessionId: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
    }
}
