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
        ("SessionEnd", .sessionEnd),
    ]

    /// The hooks block linkC injects, pointing every relevant event at the local server.
    public static func linkcHooks(port: UInt16) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (claudeEvent, kind) in singleEntryEvents {
            hooks[claudeEvent] = [matcherBlock(matcher: nil, kind: kind, port: port)]
        }
        // Notification fans out to two matchers depending on why Claude is idle.
        hooks["Notification"] = [
            matcherBlock(matcher: "permission_prompt", kind: .notificationPermission, port: port),
            matcherBlock(matcher: "idle_prompt", kind: .notificationIdle, port: port),
        ]
        return hooks
    }

    /// Deep-merge user + project settings with linkC hooks. Appends to existing hook
    /// arrays rather than clobbering them.
    public static func compose(userSettings: Data?, projectSettings: Data?, port: UInt16) throws -> Data {
        let user = try decodeSettingsObject(userSettings, label: "user")
        let project = try decodeSettingsObject(projectSettings, label: "project")

        var merged = deepMerge(user, overlay: project)
        let existingHooks = merged["hooks"] as? [String: Any] ?? [:]
        merged["hooks"] = appendLinkcHooks(linkcHooks(port: port), onto: existingHooks)

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

    private static func matcherBlock(matcher: String?, kind: HookEventKind, port: UInt16) -> [String: Any] {
        var block: [String: Any] = [
            "hooks": [
                [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)/hook",
                    "headers": [
                        "X-LinkC-Session": "$LINKC_SESSION",
                        "X-LinkC-Event": kind.rawValue,
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

    /// Folds linkC's own hook arrays into the user/project-merged `hooks` object,
    /// APPENDING to any existing array for that event rather than replacing it —
    /// this is what guarantees a linkC session still runs the user's own hooks.
    private static func appendLinkcHooks(_ linkc: [String: Any], onto existing: [String: Any]) -> [String: Any] {
        var result = existing
        for (event, linkcEntries) in linkc {
            guard let linkcArray = linkcEntries as? [Any] else { continue }
            let existingArray = result[event] as? [Any] ?? []
            result[event] = existingArray + linkcArray
        }
        return result
    }
}
