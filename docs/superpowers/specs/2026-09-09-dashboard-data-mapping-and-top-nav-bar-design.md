# Dashboard Data Mapping, Top Navigation Bar & Pure Opacity Transitions Design

## 1. Overview & Objectives

This design addresses three core UX requirements in `linkC`:
1. **Rich Dashboard Data Mapping**: Eliminates the "shows nothing" state on the dashboard by directly ingesting live terminal scrollback (`recentOutput`), active status phrases (`liveActivityLine`), and git file modifications (`git status -s`) for every active agent session, ensuring the user can immediately read and understand what each agent is doing and has contributed.
2. **Integrated Top Navigation Bar**: Adds a persistent top navigation bar directly into `PanelHeader` above the terminal and across all screens, allowing 1-click instant switching between `Home`, `Terminal`, `Activity & Dashboard`, `Skills`, `MCP`, and `Settings` from anywhere.
3. **Pure Opacity Transitions**: Replaces sliding/translate animations with smooth hardware-accelerated `.opacity` cross-fades across all view changes in `PanelView`.

---

## 2. Architecture & Data Flow

### 2.1 Live Terminal & Session Output Ingestion (`AgentDashboardAggregator.swift`)

Currently, `AgentDashboardAggregator.aggregateProject` receives:
`liveSessions: [(id: String, agent: AgentKind, status: String, activity: String?)]`

We expand the session tuple to include the agent's recent terminal scrollback:
`liveSessions: [(id: String, agent: AgentKind, status: String, activity: String?, recentOutput: String)]`

- **Fallback for `lastDeliverable`**:
  If an agent does not have a formal completion message in `inbox.json`, `dossier.lastDeliverable` automatically falls back to `recentOutput` (the last 10-15 lines of what the agent printed, executed, or generated).
- **Synthetic Live Activity Events**:
  For each live agent session with active status or output, `AgentDashboardAggregator` generates an `AgentActivityItem`:
  - `kind`: `.intentBroadcast`
  - `title`: `"\(agent.displayName) active in terminal"`
  - `body`: `activity ?? recentOutput`
  - `timestamp`: current timestamp
- **Git File Modifications**:
  `git status -s` is executed asynchronously in the background. Modified files are parsed and assigned to `dossier.modifiedFiles` so users can see concrete code impacts (e.g. `[M Sources/Auth.swift]`, `[A Tests/AuthTests.swift]`).

---

## 3. User Interface

### 3.1 Top Navigation Bar (`PanelHeader` in `PanelView.swift`)

`PanelHeader` is updated to house a permanent horizontal navigation bar:
- **Left**: Activity count badges (`CountBadge(color: running)`, `CountBadge(color: needsYou)`).
- **Center**: Nav Button Capsule:
  - **Home** (`house`): Jumps to the project list (`model.goHome()`).
  - **Terminal** (`apple.terminal`): Returns to the active terminal (`model.selectedId != nil`).
  - **Dashboard** (`bubble.left.and.text.bubble.right`): Opens the Activity & Dashboard screen (`model.open(.activity)`).
  - **Skills** (`wand.and.stars`): Opens the Skills screen (`model.open(.skills)`).
  - **MCP** (`server.rack`): Opens MCP Servers (`model.open(.mcpServers)`).
  - **Settings** (`gearshape`): Opens Settings (`model.open(.settings)`).
- **Right**: Token usage label and `+` launcher menu.

Each button features:
- Active state: Highlighted disc with `Theme.accent`.
- Hover state: Soft circular wash with tooltips.
- Always accessible above the active terminal viewport.

### 3.2 Pure Opacity Transitions (`PanelView.swift`)

All pane swapping transitions in `PanelView.swift` are standardized to:
`.transition(.opacity)`
This removes all `.asymmetric(.move(edge: .trailing).combined(with: .opacity), removal: .opacity)` directional slides, ensuring silky smooth Mac-native cross-fades when navigating.

### 3.3 Enhanced Dashboard Cards (`ActivityScreen.swift` & `ProjectDashboardSheet.swift`)

- **Agent Dossiers**:
  - Header: `AgentPill` + Live Status with `.smoothShimmer` (`WORKING`, `NEEDS YOU`, `IDLE`) + "Open Terminal" button.
  - Metrics: `[X Tasks Done]` · `[Y Files Claimed]` · `[Z Modified in Git]`.
  - Terminal Thoughts Well: Formatted dark well displaying the latest lines from the terminal.
  - Modified Files: Chips with git status letters (`M`, `A`, `D`).
- **Timeline**:
  - Real-time card feed showing active terminal actions, task assignments, and completed deliverables.

---

## 4. Testing & Verification

1. **Unit Tests**:
   - `AgentDashboardAggregatorTests.swift`: Verify `recentOutput` populates `dossier.lastDeliverable` and active sessions generate timeline events.
   - `AppCoordinatorDashboardTests.swift`: Verify `fetchGlobalDashboard` and `fetchProjectDashboard` pass `recentOutput`.
   - `DockActivityTests.swift`: Verify navigation bar routing and state bindings.
2. **Strict Concurrency**:
   - `swift build -Xswiftc -warnings-as-errors` passes with 0 warnings.
3. **Full Regression Suite**:
   - All 568+ tests pass with 0 failures (`swift test`).
4. **Release Deployment**:
   - `./build-app.sh --install` verifies clean codesign and installation.
