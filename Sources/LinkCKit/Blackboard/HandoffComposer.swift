import Foundation

/// Composes and atomically writes cross-agent handoff memos to `.linkc/HANDOFF.md`.
public struct HandoffComposer: Sendable {
    private static let placeholder = "(None recorded)"

    /// Composes a markdown handoff memo for passing context to another agent session.
    public static func compose(
        workspacePath: String,
        sourceAgent: AgentKind?,
        lastGoal: String?,
        gitSummary: String?,
        recentTerminalOutput: String?,
        timestamp: Date = Date()
    ) -> String {
        let trimmedWorkspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkspace = trimmedWorkspace.isEmpty ? placeholder : (trimmedWorkspace as NSString).standardizingPath

        let agentText: String
        if let sourceAgent {
            agentText = "[\(sourceAgent.pillText)] \(sourceAgent.displayName)"
        } else {
            agentText = placeholder
        }

        let isoDate = ISO8601DateFormatter().string(from: timestamp)

        let resolvedGoal: String
        if let lastGoal = lastGoal?.trimmingCharacters(in: .whitespacesAndNewlines), !lastGoal.isEmpty {
            resolvedGoal = lastGoal
        } else {
            resolvedGoal = placeholder
        }

        let resolvedGit: String
        if let gitSummary = gitSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !gitSummary.isEmpty {
            resolvedGit = gitSummary
        } else {
            resolvedGit = placeholder
        }

        let resolvedTerminal: String
        if let recentTerminalOutput = recentTerminalOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !recentTerminalOutput.isEmpty {
            resolvedTerminal = "```\n\(recentTerminalOutput)\n```"
        } else {
            resolvedTerminal = placeholder
        }

        return """
        # Project Handoff Memo

        **Workspace:** \(resolvedWorkspace)
        **Timestamp:** \(isoDate)
        **Source Agent:** \(agentText)

        ## Goal
        \(resolvedGoal)

        ## Git Status Summary
        \(resolvedGit)

        ## Recent Terminal Output
        \(resolvedTerminal)

        """
    }

    /// Atomically writes content to `<workspacePath>/.linkc/HANDOFF.md`.
    @discardableResult
    public static func writeHandoff(workspacePath: String, content: String) throws -> URL {
        let wsURL = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        let linkcDir = wsURL.appendingPathComponent(".linkc", isDirectory: true)
        let fm = FileManager.default

        if !fm.fileExists(atPath: linkcDir.path) {
            try fm.createDirectory(at: linkcDir, withIntermediateDirectories: true)
        }

        let targetURL = linkcDir.appendingPathComponent("HANDOFF.md")
        guard let data = content.data(using: .utf8) else {
            throw LinkCError.server("Failed to encode handoff content as UTF-8")
        }

        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    /// Composes and atomically writes handoff memo to `<workspacePath>/.linkc/HANDOFF.md`.
    @discardableResult
    public static func writeHandoffSync(
        workspacePath: String,
        sourceAgent: AgentKind?,
        lastGoal: String?,
        gitSummary: String?,
        recentTerminalOutput: String?,
        timestamp: Date = Date()
    ) throws -> URL {
        let content = compose(
            workspacePath: workspacePath,
            sourceAgent: sourceAgent,
            lastGoal: lastGoal,
            gitSummary: gitSummary,
            recentTerminalOutput: recentTerminalOutput,
            timestamp: timestamp
        )
        return try writeHandoff(workspacePath: workspacePath, content: content)
    }
}
