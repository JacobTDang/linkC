# Terminal Agent Detection & Autonomous Launch (Milestone 1)

## Overview & Goals
linkC expands from a dedicated Claude Code session manager into a universal AI mission control capable of hosting and identifying any AI agent CLI:
1. **Claude Code** (`claude`)
2. **Antigravity CLI** (`agy`)
3. **Cursor Agent CLI** (`cursor agent`)
4. **Codex CLI** (`codex`)
5. **Interactive Login Shell** (`zsh`)

### Goals
- **Explicit Autonomous Launch**: The `+` launcher menu allows launching any of the 4 agents in 1 click with `--yolo` / `--dangerously-skip-permissions` pre-configured.
- **Dynamic Terminal Detection**: In any interactive terminal (including dev shells), linkC detects if the user runs `claude`, `agy`, `cursor`, or `codex` as a child process and updates the card/row identity in real-time.
- **Visual Identity**: Distinct micro-pill badges (`CLAUDE`, `AGY`, `CURSOR`, `CODEX`) with signature brand colors on `HomeCard` and `CompactSessionRow`.

### Non-Goals (Milestone 2)
- Inter-agent communication bus, local MCP switchboard, and project-level shared blackboards are deferred to Milestone 2.

---

## Architecture & Data Model

### 1. `AgentKind`
```swift
public enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claude
    case agy
    case cursor
    case codex
    case shell

    public var pillText: String {
        switch self {
        case .claude: return "CLAUDE"
        case .agy: return "AGY"
        case .cursor: return "CURSOR"
        case .codex: return "CODEX"
        case .shell: return "SHELL"
        }
    }
}
```

### 2. `AgentDescriptor`
A registry providing metadata and CLI flags:
```swift
public struct AgentDescriptor: Sendable {
    public let kind: AgentKind
    public let binaryName: String
    public let defaultCandidatePaths: [String]
    public let yoloFlags: [String]
    public let continueArgs: [String]
    public let resumeArgs: [String]

    public static func descriptor(for kind: AgentKind) -> AgentDescriptor
    public static func resolveExecutable(for kind: AgentKind) -> String?
}
```

#### CLI Configurations & `--yolo` Flags:
| Agent | Default Candidate Paths | `--yolo` Flag | Continue Args | Resume Args |
| :--- | :--- | :--- | :--- | :--- |
| **Claude** | `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` | `["--dangerously-skip-permissions"]` | `["--continue"]` | `["--resume"]` |
| **Antigravity** | `~/.local/bin/agy`, `/opt/homebrew/bin/agy` | `["--dangerously-skip-permissions"]` | `["--continue"]` | `["--conversation"]` |
| **Cursor** | `~/.local/bin/cursor`, `/Applications/Cursor.app/Contents/Resources/app/bin/cursor` | `["agent", "--yolo"]` | `["--continue"]` | `["--resume"]` |
| **Codex** | `/opt/homebrew/bin/codex`, `/usr/local/bin/codex` | `["--dangerously-bypass-approvals-and-sandbox"]` | `["resume", "--last"]` | `["resume"]` |

---

## Dynamic Process Snooper (`ProcessSnooper`)

### Darwin C-Interop
`ProcessSnooper` queries macOS kernel process tables using `<libproc.h>`:
1. Calls `proc_listpids(PROC_PPID_ONLY, childPid, buffer, size)` to find children of the shell PTY.
2. For each child PID, queries `proc_pidpath(pid, buffer, size)` to obtain the absolute executable path.
3. Matches the path's filename / components:
   - `*/claude` &rarr; `.claude`
   - `*/agy` &rarr; `.agy`
   - `*/cursor` &rarr; `.cursor`
   - `*/codex` &rarr; `.codex`
4. If a match is found, updates `TerminalSession.activeAgent`. If children exit or return to the shell prompt, reverts to `.shell` (or the launch-time agent).

### Cadence
The snooper runs at a 1.0s periodic cadence (piggybacking on the existing `TimelineView` / preview scraper in `SessionListColumn`), resulting in negligible CPU usage (<0.05ms per tick).

---

## UI Components

### 1. `AgentPill`
Rendered in `Sources/linkc/SessionList.swift`:
```swift
struct AgentPill: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.pillText)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(0.25), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
```

Brand Colors:
- Claude: `#D97757` (Coral)
- Antigravity: `#7AA2F7` (Gemini Blue)
- Cursor: `#00E5FF` (Cyan)
- Codex: `#10A37F` (Emerald Green)
- Shell: `#8E8E93` (Secondary / Muted)

### 2. Integration Points
- **`HomeCard`**: Rendered immediately following `session.title`.
- **`CompactSessionRow`**: Rendered in `middle` or beside the title.
- **`CompactTerminalRow`**: Displays `detectedAgent` dynamically.
- **`LauncherMenu`**: Exposes direct 1-click launch for all 4 agents plus dev shell, with Continue/Resume submenus.

---

## Testing & Verification Plan

1. **Unit Tests (`LinkCKitTests`)**:
   - `AgentDescriptorTests`: Test argument generation for all 4 agents across `.new`, `.continueLast`, and `.resume`. Verify `--yolo` flag injection.
   - `ProcessSnooperTests`: Test process name matching against synthetic and real process trees.
2. **Integration Verification**:
   - `swift build` and `swift test` (pass all 369 existing tests without regression).
   - Launch each agent via LinkC and verify process starts in `--yolo` mode.
   - Launch interactive shell and run CLI agent to verify dynamic badge update.
