import Foundation

public struct AgentDashboardAggregator: Sendable {
    public init() {}

    public func aggregateProject(
        workspacePath: String,
        liveSessions: [(id: String, agent: AgentKind, status: String, activity: String?)]
    ) -> ProjectDashboardData {
        let norm = (workspacePath as NSString).standardizingPath
        let title = (norm as NSString).lastPathComponent

        let inboxStore = InboxStore(workspaceRoot: norm)
        let blackboardStore = BlackboardStore(workspaceRoot: norm)

        let inbox = (try? inboxStore.load()) ?? Inbox(workspacePath: norm)
        let blackboard = (try? blackboardStore.load()) ?? Blackboard(projectPath: norm)

        var activityItems: [AgentActivityItem] = []
        var completedCounts: [AgentKind: Int] = [:]
        var claimedFilesByAgent: [AgentKind: Set<String>] = [:]
        var lastDeliverables: [AgentKind: String] = [:]
        var lastDeliverableTimes: [AgentKind: Date] = [:]

        // 1. Process Inbox Messages
        for msg in inbox.messages {
            let isCompletion = msg.prompt.hasPrefix("[Task Completed by")
            let kind: AgentActivityKind = isCompletion ? .completedTask : .delegatedTask
            let itemTitle: String
            let itemBody: String

            if isCompletion {
                itemTitle = "\(msg.fromAgent.displayName) completed task for \(msg.toAgent.displayName)"
                // Strip header if possible to isolate result
                if let resultRange = msg.prompt.range(of: "Result / Output:\n") {
                    itemBody = String(msg.prompt[resultRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    itemBody = msg.prompt
                }
                completedCounts[msg.fromAgent, default: 0] += 1
                let msgTime = msg.deliveredAt ?? msg.createdAt
                if let prevTime = lastDeliverableTimes[msg.fromAgent] {
                    if msgTime >= prevTime {
                        lastDeliverables[msg.fromAgent] = itemBody
                        lastDeliverableTimes[msg.fromAgent] = msgTime
                    }
                } else {
                    lastDeliverables[msg.fromAgent] = itemBody
                    lastDeliverableTimes[msg.fromAgent] = msgTime
                }
            } else {
                itemTitle = "\(msg.fromAgent.displayName) delegated task to \(msg.toAgent.displayName)"
                itemBody = msg.prompt
            }

            let assignee = isCompletion ? msg.fromAgent : msg.toAgent
            for file in msg.claimedFiles {
                claimedFilesByAgent[assignee, default: []].insert(file)
            }

            activityItems.append(
                AgentActivityItem(
                    id: "msg-\(msg.id)",
                    timestamp: msg.deliveredAt ?? msg.createdAt,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: msg.fromAgent,
                    toAgent: msg.toAgent,
                    kind: kind,
                    title: itemTitle,
                    body: itemBody,
                    claimedFiles: msg.claimedFiles
                )
            )
        }

        // 2. Process Shared Notes
        for note in blackboard.sharedNotes {
            activityItems.append(
                AgentActivityItem(
                    id: "note-\(note.id)",
                    timestamp: note.createdAt,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: note.authorAgent,
                    toAgent: nil,
                    kind: .sharedNote,
                    title: "\(note.authorAgent.displayName) shared note: \(note.title)",
                    body: note.content,
                    claimedFiles: []
                )
            )
        }

        // 3. Process Rate Limits
        for (idx, limit) in inbox.agentLimits.enumerated() {
            activityItems.append(
                AgentActivityItem(
                    id: "limit-\(limit.agent.rawValue)-\(idx)",
                    timestamp: limit.limitedAt,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: limit.agent,
                    toAgent: nil,
                    kind: .rateLimited,
                    title: "\(limit.agent.displayName) Rate Limited",
                    body: limit.reason,
                    claimedFiles: []
                )
            )
        }

        // 4. Process Intent Broadcasts from recent events
        for (idx, event) in blackboard.recentEvents.enumerated() where event.action == "broadcast_intent" {
            activityItems.append(
                AgentActivityItem(
                    id: "event-intent-\(idx)-\(event.agentKind.rawValue)",
                    timestamp: event.timestamp,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: event.agentKind,
                    toAgent: nil,
                    kind: .intentBroadcast,
                    title: "\(event.agentKind.displayName) broadcast goal",
                    body: event.details,
                    claimedFiles: []
                )
            )
        }

        // 5. Process Active Agent Records
        for record in blackboard.activeAgents {
            for file in record.claimedFiles {
                claimedFilesByAgent[record.agentKind, default: []].insert(file)
            }
        }

        // 6. Inspect modified files in git
        let modifiedFiles = inspectGitModifiedFiles(at: norm)

        // 7. Compile Dossiers
        var dossiers: [AgentContributionDossier] = []
        let allAgentsInProject = Set(liveSessions.map { $0.agent })
            .union(inbox.messages.map { $0.fromAgent })
            .union(inbox.messages.map { $0.toAgent })
            .union(inbox.agentLimits.map { $0.agent })
            .union(blackboard.activeAgents.map { $0.agentKind })
            .union(blackboard.sharedNotes.map { $0.authorAgent })
            .union(blackboard.recentEvents.filter { $0.action == "broadcast_intent" }.map { $0.agentKind })
            .filter { $0 != .shell }

        for agent in allAgentsInProject {
            let session = liveSessions.first(where: { $0.agent == agent })
            let dossier = AgentContributionDossier(
                agent: agent,
                workspacePath: norm,
                activeSessionId: session?.id,
                status: session?.status ?? "idle",
                liveActivity: session?.activity,
                completedTasksCount: completedCounts[agent] ?? 0,
                claimedFiles: Array(claimedFilesByAgent[agent] ?? []).sorted(),
                modifiedFiles: modifiedFiles,
                lastDeliverable: lastDeliverables[agent],
                notesAuthoredCount: blackboard.sharedNotes.filter { $0.authorAgent == agent }.count
            )
            dossiers.append(dossier)
        }

        // Sort items newest first
        activityItems.sort { $0.timestamp > $1.timestamp }
        dossiers.sort { $0.agent.displayName < $1.agent.displayName }

        // 8. Check collisions across active agents without self-matching
        var collisions: [CollisionWarning] = []
        var seenPairs = Set<String>()
        for record in blackboard.activeAgents {
            guard !record.claimedFiles.isEmpty else { continue }
            let warnings = (try? blackboardStore.checkConflicts(files: record.claimedFiles, excludingPid: record.pid)) ?? []
            for warning in warnings {
                let minPid = min(record.pid, warning.pid)
                let maxPid = max(record.pid, warning.pid)
                let filesKey = warning.conflictingFiles.sorted().joined(separator: "|")
                let pairKey = "\(minPid)-\(maxPid):\(filesKey)"
                if seenPairs.insert(pairKey).inserted {
                    collisions.append(warning)
                }
            }
        }

        return ProjectDashboardData(
            workspacePath: norm,
            projectTitle: title,
            activityItems: activityItems,
            dossiers: dossiers,
            sharedNotes: blackboard.sharedNotes,
            collisions: collisions
        )
    }

    public func aggregateGlobal(
        workspaces: [String],
        liveSessions: [(id: String, workspace: String, agent: AgentKind, status: String, activity: String?)]
    ) -> GlobalDashboardData {
        var allItems: [AgentActivityItem] = []
        var allDossiers: [AgentContributionDossier] = []

        let uniqueWorkspaces = Array(Set(workspaces.map { ($0 as NSString).standardizingPath })).sorted()

        for norm in uniqueWorkspaces {
            let matchingSessions = liveSessions
                .filter { ($0.workspace as NSString).standardizingPath == norm }
                .map { ($0.id, $0.agent, $0.status, $0.activity) }
            let projData = aggregateProject(workspacePath: norm, liveSessions: matchingSessions)
            allItems.append(contentsOf: projData.activityItems)
            allDossiers.append(contentsOf: projData.dossiers)
        }

        allItems.sort { $0.timestamp > $1.timestamp }
        return GlobalDashboardData(
            activityItems: allItems,
            dossiers: allDossiers,
            activeProjectCount: uniqueWorkspaces.count
        )
    }

    private func inspectGitModifiedFiles(at path: String) -> [String] {
        let gitPath: String
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            gitPath = "/usr/bin/git"
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git") {
            gitPath = "/opt/homebrew/bin/git"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/git") {
            gitPath = "/usr/local/bin/git"
        } else {
            return []
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", path, "status", "-s"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line -> String? in
                let lineStr = String(line)
                guard lineStr.count >= 4 else { return nil }
                var pathPart = String(lineStr.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if let arrowRange = pathPart.range(of: " -> ") {
                    pathPart = String(pathPart[arrowRange.upperBound...])
                }
                pathPart = pathPart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return pathPart.isEmpty ? nil : pathPart
            }
        } catch {
            return []
        }
    }
}

extension BlackboardStore {
    @discardableResult
    public func addSharedNote(
        authorAgent: AgentKind,
        title: String,
        content: String,
        tags: [String] = [],
        timeout: TimeInterval = 5.0
    ) throws -> SharedNote {
        try postNote(authorAgent: authorAgent, title: title, content: content, tags: tags, timeout: timeout)
    }
}
