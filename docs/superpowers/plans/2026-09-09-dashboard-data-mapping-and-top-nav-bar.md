# Dashboard Data Mapping, Top Navigation Bar & Pure Opacity Transitions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide rich, understandable live dashboard cards populated with real terminal output and git changes, add an integrated top navigation bar above the terminal, and deliver silky smooth pure opacity cross-fade transitions across linkC.

**Architecture:** `AgentDashboardAggregator` directly extracts live terminal scrollback (`recentOutput`) and active phrases from `TerminalSession`, populating `lastDeliverable` and real-time activity items. `PanelHeader` in `PanelView` is upgraded with a persistent horizontal `TopNavBar` connecting all screens. All pane transitions are standardized to pure `.opacity`.

**Tech Stack:** Swift 6, SwiftUI, SwiftTerm, LinkCKit, AppKit, XCTest.

## Global Constraints

- Target platform: macOS 14+ (arm64/x86_64).
- Strict Swift 6 concurrency (`.v6`) with 0 warnings (`swift build -Xswiftc -warnings-as-errors`).
- All existing 568 tests must continue to pass without regressions (`swift test`).
- Strictly zero tolerance for forbidden words in code, comments, plans, or commit messages.
- Production build & install via `./build-app.sh --install` into `/Applications/linkC.app`.

---

### Task 1: Live Terminal Scrollback & Session Output Aggregation (`AgentDashboardAggregator.swift` & `AppCoordinator.swift`)

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Test: `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorDashboardTests.swift`

**Interfaces:**
- Consumes: `TerminalSession.recentOutput(lines:)`, `TerminalSession.liveActivityLine()`
- Produces:
  - `AgentDashboardAggregator.aggregateProject(workspacePath:liveSessions:)` with `recentOutput: String` in tuple
  - `AgentDashboardAggregator.aggregateGlobal(workspaces:liveSessions:)` with `recentOutput: String` in tuple

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift
func testAggregateExtractsLiveSessionScrollbackAndGeneratesLiveActivity() {
    let ws = (tempDir.path as NSString).standardizingPath
    let aggregator = AgentDashboardAggregator()

    let liveSessions = [(
        id: "s-live-1",
        agent: AgentKind.cursor,
        status: "working",
        activity: Optional("Compiling Auth.swift"),
        recentOutput: "Running build step...\nGenerated 12 symbols.\nAll clear."
    )]

    let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

    // Dossier should fall back lastDeliverable to recentOutput when no inbox message exists
    let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
    XCTAssertNotNil(cursorDossier)
    XCTAssertEqual(cursorDossier?.lastDeliverable, "Running build step...\nGenerated 12 symbols.\nAll clear.")
    XCTAssertEqual(cursorDossier?.liveActivity, "Compiling Auth.swift")

    // Timeline should include an activity item for the live active session
    let liveItem = data.activityItems.first(where: { $0.fromAgent == .cursor && $0.title.contains("active in terminal") })
    XCTAssertNotNil(liveItem)
    XCTAssertTrue(liveItem?.body.contains("Generated 12 symbols") ?? false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testAggregateExtractsLiveSessionScrollbackAndGeneratesLiveActivity`
Expected: FAIL (tuple signature mismatch)

- [ ] **Step 3: Update `AgentDashboardAggregator.swift` and `AppCoordinator.swift`**

In `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`:
Update `aggregateProject` signature and implementation:
```swift
    public func aggregateProject(
        workspacePath: String,
        liveSessions: [(id: String, agent: AgentKind, status: String, activity: String?, recentOutput: String)]
    ) -> ProjectDashboardData {
```
And inside `aggregateProject`:
1. When assembling `dossiers`, if `lastDeliverables[agent] == nil`, check if a matching live session has non-empty `recentOutput`:
```swift
            let session = liveSessions.first(where: { $0.agent == agent })
            let deliverable = lastDeliverables[agent] ?? (session?.recentOutput.isEmpty == false ? session?.recentOutput : nil)
```
2. For each active live session with non-empty activity or output, append a synthesized `AgentActivityItem`:
```swift
        for session in liveSessions where !session.recentOutput.isEmpty || session.activity != nil {
            let desc = session.activity ?? "Active in terminal"
            let body = session.recentOutput.isEmpty ? desc : session.recentOutput
            activityItems.append(
                AgentActivityItem(
                    id: "live-session-\(session.id)",
                    timestamp: Date(),
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: session.agent,
                    toAgent: nil,
                    kind: .intentBroadcast,
                    title: "\(session.agent.displayName) active in terminal",
                    body: body,
                    claimedFiles: []
                )
            )
        }
```
Update `aggregateGlobal` signature to accept `(id: String, workspace: String, agent: AgentKind, status: String, activity: String?, recentOutput: String)`.

In `Sources/LinkCKit/App/AppCoordinator.swift`:
In `fetchProjectDashboard` and `fetchGlobalDashboard`:
Query `terminals.session(id: s.id)?.recentOutput(lines: 15) ?? ""` and pass it in the session tuples.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentDashboardAggregatorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift Tests/LinkCKitTests/AppCoordinatorDashboardTests.swift
git commit -m "feat(blackboard): ingest live terminal scrollback and synthesize active timeline items"
```

---

### Task 2: Persistent Top Navigation Bar & Pure Opacity Transitions (`PanelView.swift` & `Dock.swift`)

**Files:**
- Modify: `Sources/linkc/PanelView.swift`
- Modify: `Sources/linkc/Dock.swift`
- Test: `Tests/LinkCKitTests/TopNavBarTests.swift`

**Interfaces:**
- Consumes: `AppModel.activeScreen`, `AppModel.selectedId`, `AppModel.open(_:)`, `AppModel.goHome()`, `AppModel.focus(_:)`
- Produces: `struct TopNavBar: View`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LinkCKitTests/TopNavBarTests.swift
import XCTest
@testable import LinkCKit

final class TopNavBarTests: XCTestCase {
    func testPanelScreenCasesForTopNav() {
        let expectedScreens: [PanelScreen] = [.activity, .skills, .mcpServers, .settings]
        for screen in expectedScreens {
            XCTAssertTrue(PanelScreen.allCases.contains(screen))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter TopNavBarTests`
Expected: PASS

- [ ] **Step 3: Implement `TopNavBar` and update `PanelHeader` & transitions in `PanelView.swift`**

In `Sources/linkc/PanelView.swift`:
1. Implement `struct TopNavBar: View`:
```swift
struct TopNavBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            navButton(icon: "house", help: "Home / Projects", isSelected: model.selectedId == nil && model.activeScreen == nil) {
                model.goHome()
            }
            if let activeId = model.selectedId ?? model.sessions.first?.id {
                navButton(icon: "apple.terminal", help: "Active Terminal", isSelected: model.selectedId != nil && model.activeScreen == nil) {
                    model.focus(activeId)
                }
            }
            navButton(icon: "bubble.left.and.text.bubble.right", help: "Agent Activity & Dashboard", isSelected: model.activeScreen == .activity) {
                model.open(.activity)
            }
            navButton(icon: "wand.and.stars", help: "Skills", isSelected: model.activeScreen == .skills) {
                model.open(.skills)
            }
            navButton(icon: "server.rack", help: "MCP Servers", isSelected: model.activeScreen == .mcpServers) {
                model.open(.mcpServers)
            }
            navButton(icon: "gearshape", help: "Settings", isSelected: model.activeScreen == .settings) {
                model.open(.settings)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func navButton(icon: String, help: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .frame(width: 26, height: 24)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.accent)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
```

2. Add `TopNavBar(model: model)` into `PanelHeader`:
Place `TopNavBar(model: model)` in the center between the badges and launcher.

3. In `PanelView.body`, change all pane transitions:
Replace all `.asymmetric(.move(edge: .trailing).combined(with: .opacity), removal: .opacity)` and `.move(edge: .leading)` with `.opacity`.

- [ ] **Step 4: Verify compilation with zero warnings**

Run: `swift build -Xswiftc -warnings-as-errors`
Expected: Build complete!

- [ ] **Step 5: Commit**

```bash
git add Sources/linkc/PanelView.swift Sources/linkc/Dock.swift Tests/LinkCKitTests/TopNavBarTests.swift
git commit -m "feat(ui): add persistent TopNavBar in header and pure opacity transitions across all panes"
```

---

### Task 3: Redesigned Agent Dashboard Cards & Timeline View (`ActivityScreen.swift` & `ProjectDashboardSheet.swift`)

**Files:**
- Modify: `Sources/linkc/Screens/ActivityScreen.swift`
- Modify: `Sources/linkc/ProjectDashboardSheet.swift`

**Interfaces:**
- Consumes: `AgentContributionDossier`, `AgentActivityItem`, `ProjectDashboardData`, `GlobalDashboardData`
- Produces: Enhanced UI cards with formatted terminal output wells, live shimmer indicators, and git status badges.

- [ ] **Step 1: Write/update unit tests for UI data mapping**

Verify in `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift` that `dossier.modifiedFiles` and `lastDeliverable` contain expected terminal and git content.

- [ ] **Step 2: Update `ActivityScreen.swift`**

In `Sources/linkc/Screens/ActivityScreen.swift`:
1. Enhance `dossierCard`:
   - Header with `AgentPill`, live activity phrase with `.smoothShimmer(isWorking: dossier.status == "working")`, state tag, and prominent `Button("Open Terminal") { model.focus(sid) }`.
   - Metrics row: `[X Tasks Done]` · `[Y Files Claimed]` · `[Z Modified in Git]`.
   - Formatted Terminal Thoughts Well:
     ```swift
     if let thoughts = dossier.lastDeliverable, !thoughts.isEmpty {
         VStack(alignment: .leading, spacing: 4) {
             Text("LATEST TERMINAL THOUGHTS / OUTPUT")
                 .font(.system(size: 9, weight: .bold))
                 .tracking(0.6)
                 .foregroundStyle(Theme.textTertiary)
             Text(thoughts)
                 .font(.system(size: 10.5, design: .monospaced))
                 .foregroundStyle(Theme.textPrimary)
                 .lineLimit(6)
                 .padding(8)
                 .frame(maxWidth: .infinity, alignment: .leading)
                 .background(Color.black.opacity(0.35))
                 .clipShape(RoundedRectangle(cornerRadius: 6))
                 .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
         }
     }
     ```
   - Modified Files List:
     ```swift
     if !dossier.modifiedFiles.isEmpty {
         VStack(alignment: .leading, spacing: 4) {
             Text("FILES MODIFIED IN WORKSPACE (\(dossier.modifiedFiles.count))")
                 .font(.system(size: 9, weight: .bold))
                 .tracking(0.6)
                 .foregroundStyle(Theme.textTertiary)
             FlowLayout(spacing: 4) {
                 ForEach(dossier.modifiedFiles.prefix(8), id: \.self) { file in
                     Text(file)
                         .font(.system(size: 10, design: .monospaced))
                         .padding(.horizontal, 6)
                         .padding(.vertical, 2)
                         .background(Color.white.opacity(0.06))
                         .clipShape(RoundedRectangle(cornerRadius: 4))
                 }
             }
         }
     }
     ```
2. Enhance `timelineCard`:
   - Monospaced code well for prompt or result body.

- [ ] **Step 3: Update `ProjectDashboardSheet.swift`**

Apply the same enhanced cards in `filesSection` and `timelineSection` of `ProjectDashboardSheet.swift`.

- [ ] **Step 4: Verify build with zero warnings**

Run: `swift build -Xswiftc -warnings-as-errors`
Expected: Build complete!

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/linkc/Screens/ActivityScreen.swift Sources/linkc/ProjectDashboardSheet.swift
git commit -m "feat(ui): enhance dashboard cards with terminal output wells, live shimmer, and git status"
```

---

### Task 4: Verification, End-to-End Build & Release Installation

**Files:**
- All modified and new files.

- [ ] **Step 1: Run complete test suite**

Run: `swift test`
Expected: 568+ tests pass with 0 failures.

- [ ] **Step 2: Verify zero compiler warnings**

Run: `swift build -Xswiftc -warnings-as-errors`
Expected: Exit code 0, 0 warnings.

- [ ] **Step 3: Compile and install release bundle**

Run: `./build-app.sh --install`
Expected: Clean build, code-signed, installed to `/Applications/linkC.app`.

- [ ] **Step 4: Commit any adjustments**

```bash
git commit -am "chore(release): verify all tests and deploy dashboard data mapping and top nav bar"
```
