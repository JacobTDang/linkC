import Foundation

/// Produces the per-session settings JSON passed via `claude --settings`.
/// Deep-merges the user's global + project settings with linkC's hooks so a linkC
/// session behaves identically to a normal one, plus reports its lifecycle.
public enum SettingsComposer {
    /// The four Claude Code events that get exactly one linkC hook entry, with no matcher.
    private static let singleEntryEvents: [(claudeEvent: String, kind: HookEventKind)] = [
        ("SessionStart", .sessionStart),
        ("UserPromptSubmit", .userPromptSubmit),
        ("Stop", .stop),
        ("StopFailure", .stopFailure),   // API-error turn end — without it, sessions stick at "working"
        ("SessionEnd", .sessionEnd),
    ]

    /// The hooks block linkC injects, pointing every relevant event at the local server.
    public static func linkcHooks(port: UInt16, token: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (claudeEvent, kind) in singleEntryEvents {
            hooks[claudeEvent] = [matcherBlock(matcher: nil, kind: kind, port: port, token: token)]
        }
        // Notification fans out to two matchers depending on why Claude is idle.
        hooks["Notification"] = [
            matcherBlock(matcher: "permission_prompt", kind: .notificationPermission, port: port, token: token),
            matcherBlock(matcher: "idle_prompt", kind: .notificationIdle, port: port, token: token),
        ]
        return hooks
    }

    /// Deep-merge user + project settings with linkC hooks. Appends to existing hook
    /// arrays rather than clobbering them.
    public static func compose(userSettings: Data?, projectSettings: Data?, port: UInt16, token: String) throws -> Data {
        let user = try decodeSettingsObject(userSettings, label: "user")
        let project = try decodeSettingsObject(projectSettings, label: "project")

        // Merge everything EXCEPT hooks with last-writer-wins (project over user). The
        // `hooks` object is special-cased: a generic deep merge would let the project's
        // array for an event replace the user's, silently dropping the user's hook for any
        // event they both define. Instead, each event's arrays are concatenated so hooks
        // from user, project, and linkC all survive.
        let userHooks = user["hooks"] as? [String: Any] ?? [:]
        let projectHooks = project["hooks"] as? [String: Any] ?? [:]

        var merged = deepMerge(user, overlay: project)
        let userAndProjectHooks = concatHookArrays(base: userHooks, appending: projectHooks)
        merged["hooks"] = concatHookArrays(base: userAndProjectHooks, appending: linkcHooks(port: port, token: token))

        guard JSONSerialization.isValidJSONObject(merged) else {
            throw LinkCError.parse("composed settings could not be represented as JSON")
        }
        do {
            return try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw LinkCError.parse("failed to serialize composed settings: \(error)")
        }
    }

    // MARK: - linkcHooks construction

    private static func matcherBlock(matcher: String?, kind: HookEventKind, port: UInt16, token: String) -> [String: Any] {
        var block: [String: Any] = [
            "hooks": [
                [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)/hook",
                    "headers": [
                        "X-LinkC-Session": "$LINKC_SESSION",
                        "X-LinkC-Event": kind.rawValue,
                        // Per-run shared secret: the server drops events without it, so no
                        // other local process can spoof session state at the loopback port.
                        "X-LinkC-Token": token,
                    ],
                    "allowedEnvVars": ["LINKC_SESSION"],
                ],
            ],
        ]
        if let matcher {
            block["matcher"] = matcher
        }
        return block
    }

    // MARK: - Settings decoding

    /// nil/empty settings blobs are treated as `{}` — nothing to preserve, nothing to fail on.
    private static func decodeSettingsObject(_ data: Data?, label: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LinkCError.parse("\(label) settings JSON is not an object")
            }
            return object
        } catch let error as LinkCError {
            throw error
        } catch {
            throw LinkCError.parse("failed to decode \(label) settings JSON: \(error)")
        }
    }

    // MARK: - Merging

    /// Generic recursive merge: nested objects merge key-by-key; anything else
    /// (arrays, strings, numbers, ...) in `overlay` wins outright over `base`.
    private static func deepMerge(_ base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, overlayValue) in overlay {
            if let baseDict = result[key] as? [String: Any], let overlayDict = overlayValue as? [String: Any] {
                result[key] = deepMerge(baseDict, overlay: overlayDict)
            } else {
                result[key] = overlayValue
            }
        }
        return result
    }

    /// Merge two `hooks` objects by CONCATENATING each event's arrays — `base` first, then
    /// `appending` — rather than letting one replace the other. Used to fold user, project,
    /// and linkC hooks together so a linkC session still runs every hook that was configured
    /// for an event, no matter which layer defined it. A non-array value in `appending`
    /// (unexpected shape) overwrites, matching last-writer-wins for malformed input.
    private static func concatHookArrays(base: [String: Any], appending: [String: Any]) -> [String: Any] {
        var result = base
        for (event, value) in appending {
            guard let appendArray = value as? [Any] else {
                result[event] = value
                continue
            }
            let baseArray = result[event] as? [Any] ?? []
            result[event] = baseArray + appendArray
        }
        return result
    }
}
