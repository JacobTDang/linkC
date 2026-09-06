# Persistent Session & Terminal Auto-Restore Across Updates & Launches

## Overview
When users update or reinstall linkC (via in-app update, `build-app.sh --install`, or manual app replacement) or quit and relaunch the application, all active terminals, AI agents (Claude, Antigravity/agy, Codex, Cursor), and shell sessions must be preserved and automatically relaunched with their respective configurations, working directories, and resume states.

---

## 1. Data Model & Storage

### 1.1 Enhanced `RestorableSession`
In `Sources/LinkCKit/App/WorkspaceManifest.swift`:
```swift
public struct RestorableSession: Codable, Equatable, Identifiable, Sendable {
    public let linkcId: String
    public var claudeSessionId: String?
    public let cwd: String
    public let title: String
    public var agentKind: AgentKind
    public var wasActiveOnQuit: Bool
    public var endedAt: Date?

    public var id: String { linkcId }

    public init(
        linkcId: String,
        claudeSessionId: String? = nil,
        cwd: String,
        title: String,
        agentKind: AgentKind = .claude,
        wasActiveOnQuit: Bool = false,
        endedAt: Date? = nil
    ) {
        self.linkcId = linkcId
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.title = title
        self.agentKind = agentKind
        self.wasActiveOnQuit = wasActiveOnQuit
        self.endedAt = endedAt
    }
}
```
- Custom decoding handles legacy JSON without `agentKind` (defaulting to `.claude`) and without `wasActiveOnQuit` (defaulting to `false`).

### 1.2 Enhanced `RestorableShell`
In `Sources/LinkCKit/Terminal/ShellManifest.swift`:
```swift
public struct RestorableShell: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let title: String
    public let command: String?
    public var wasActiveOnQuit: Bool
    public var detectedAgent: AgentKind?
    public var endedAt: Date?

    public init(
        id: String,
        cwd: String,
        title: String,
        command: String? = nil,
        wasActiveOnQuit: Bool = false,
        detectedAgent: AgentKind? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.command = command
        self.wasActiveOnQuit = wasActiveOnQuit
        self.detectedAgent = detectedAgent
        self.endedAt = endedAt
    }
}
```

### 1.3 Pruning & Retention Rules
- In `WorkspaceManifest.prune` and `ShellManifest.prune`:
  - Any session or shell marked `wasActiveOnQuit == true` is **never pruned** by folder deduplication (`newestByFolder`). Multiple concurrent sessions running in the same folder are preserved.
  - Ended sessions older than 7 days continue to age out.
- File paths:
  - `~/Library/Application Support/linkC/workspace.json`
  - `~/Library/Application Support/linkC/shells.json`
  - These persist across app bundle updates, renames, and replacements.

---

## 2. Lifecycle & Auto-Restore Flow

### 2.1 Pre-Termination State Snapshot
- Before app termination in `AppDelegate.applicationWillTerminate`, or before `AppModel.installUpdate()` triggers `UpdateSwap`:
  - `AppCoordinator.prepareForShutdown()`:
    1. Iterates over all active sessions in `store.sessions` where `state != .ended`.
    2. Queries latest foreground agent via `terminalSession.sampleForegroundAgent()`.
    3. Upserts each active session into `WorkspaceManifest` with `wasActiveOnQuit = true` and `endedAt = nil`.
    4. For all running shells in `ShellCoordinator`, upserts each with `wasActiveOnQuit = true`.
    5. Stores the currently selected session ID in `UserDefaults` (`"LastSelectedSessionId"`).
    6. Flushes manifest files to disk atomically.

### 2.2 Startup Auto-Resume
- During `AppCoordinator.start()`:
  1. Inspects `manifest.entries` for any entries with `wasActiveOnQuit == true`.
  2. For each active session entry:
     - Attempts to launch:
       ```swift
       launch(cwd: r.cwd, title: r.title, agent: r.agentKind, mode: .continueLast, resumeId: r.claudeSessionId)
       ```
     - If the working directory no longer exists, logs a warning and leaves it in `restorables` as an archived session with `wasActiveOnQuit = false`.
     - Upon successful launch, removes or updates the entry's `wasActiveOnQuit` flag to `false`.
  3. For each active shell entry with `wasActiveOnQuit == true`:
     - Relaunches via `ShellCoordinator.relaunch(...)`.
  4. Restores active tab selection to `"LastSelectedSessionId"` if valid.

---

## 3. Resilience & Backward Compatibility
- Graceful decoding fallbacks prevent crashes on existing configurations.
- Parallel multi-agent auto-launches avoid blocking UI initialization.
- Project blackboard advisory locks (`flock`) protect parallel startup in shared directories.

---

## 4. Verification Plan
- Unit tests in `LinkCKitTests`:
  - `WorkspaceManifestTests`: verify `agentKind` persistence, legacy decoding fallback, and multi-session retention for `wasActiveOnQuit`.
  - `ShellManifestTests`: verify `wasActiveOnQuit` retention and decoding.
  - `AppCoordinatorTests`: verify snapshot on shutdown and auto-restore loop on launch.
- End-to-end build test:
  - Full clean build and `swift test` under Swift 6 strict concurrency (`.v6`).
  - `./build-app.sh --install` validation.
