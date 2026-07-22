# Empty State Launcher & Earlier Section Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the empty state the single launcher (hiding the header `+` while it shows) and reorganize the Earlier section so "Restore all" sits inline in the header and only appears with 2+ sessions.

**Architecture:** A pure `endedLabel(now:)` helper joins `RestorableSession` in LinkCKit (unit-tested); all layout changes live in `Sources/linkc/PanelView.swift`, which already holds every view being touched. No new files beyond tests.

**Tech Stack:** Swift 6 / SwiftUI, XCTest via `swift test`, app bundle via `./build-app.sh`.

## Global Constraints

- Commit messages: simple, descriptive, no attribution lines, never mention Claude.
- Fail loud — no silent fallbacks.
- Motion/theme/card behavior untouched; every new appearance/disappearance respects Reduce Motion (plain fade).
- UI copy: "ended just now", `EARLIER · Restore all`, `Continue last · Resume…`, `quit linkC`.

---

### Task 1: `endedLabel(now:)` on RestorableSession

**Files:**
- Modify: `Sources/LinkCKit/App/WorkspaceManifest.swift` (add extension after the `RestorableSession` struct, ~line 33)
- Test: `Tests/LinkCKitTests/WorkspaceManifestTests.swift`

**Interfaces:**
- Consumes: `RestorableSession` (existing: `linkcId`, `cwd`, `title`, `endedAt: Date?`).
- Produces: `public func endedLabel(now: Date) -> String?` — `nil` while live; `"ended just now"` when `|now − endedAt| < 60s`; otherwise `"ended " + RelativeDateTimeFormatter` abbreviated output (e.g. "ended 5m ago").

- [ ] **Step 1: Write the failing tests**

Append inside `final class WorkspaceManifestTests` in `Tests/LinkCKitTests/WorkspaceManifestTests.swift` (the `entry(_:claude:cwd:title:endedAt:)` helper already exists in this class):

```swift
// MARK: - endedLabel

func testEndedLabelNilWhileLive() {
    XCTAssertNil(entry("L1").endedLabel(now: Date(timeIntervalSince1970: 1_700_000_000)))
}

func testEndedLabelJustNowUnderAMinute() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Fresh, 30s old, and slight future clock skew all read as "just now" — never "in 0s".
    XCTAssertEqual(entry("L1", endedAt: now).endedLabel(now: now), "ended just now")
    XCTAssertEqual(entry("L1", endedAt: now.addingTimeInterval(-30)).endedLabel(now: now), "ended just now")
    XCTAssertEqual(entry("L1", endedAt: now.addingTimeInterval(5)).endedLabel(now: now), "ended just now")
}

func testEndedLabelRelativeBeyondAMinute() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let label = entry("L1", endedAt: now.addingTimeInterval(-5 * 60)).endedLabel(now: now)
    let unwrapped = try XCTUnwrap(label)
    XCTAssertTrue(unwrapped.hasPrefix("ended "), "got: \(unwrapped)")
    XCTAssertNotEqual(unwrapped, "ended just now")
    XCTAssertTrue(unwrapped.contains("5"), "expected the 5-minute figure in: \(unwrapped)")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorkspaceManifestTests 2>&1 | tail -20`
Expected: compile FAILURE — `value of type 'RestorableSession' has no member 'endedLabel'`.

- [ ] **Step 3: Write the implementation**

In `Sources/LinkCKit/App/WorkspaceManifest.swift`, directly after the `RestorableSession` struct's closing brace (line 33):

```swift
/// Shared, reused across rows — formatter construction is not cheap. UI-thread only.
private let endedFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

extension RestorableSession {
    /// Human label for when the session ended: `nil` while live, "ended just now" inside a
    /// minute (either direction, so slight clock skew never renders "in 0s"), otherwise the
    /// abbreviated relative form ("ended 5m ago").
    public func endedLabel(now: Date) -> String? {
        guard let endedAt else { return nil }
        if abs(now.timeIntervalSince(endedAt)) < 60 { return "ended just now" }
        return "ended " + endedFormatter.localizedString(for: endedAt, relativeTo: now)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorkspaceManifestTests 2>&1 | tail -5`
Expected: all WorkspaceManifestTests PASS, including the 3 new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/App/WorkspaceManifest.swift Tests/LinkCKitTests/WorkspaceManifestTests.swift
git commit -m "Add endedLabel(now:) to RestorableSession; sub-minute reads as just now"
```

---

### Task 2: Earlier section — inline Restore all, row uses endedLabel

**Files:**
- Modify: `Sources/linkc/PanelView.swift:291-404` (`EarlierSection`, `RestorableRow`)

**Interfaces:**
- Consumes: `RestorableSession.endedLabel(now:)` from Task 1; existing `model.restoreAll()`, `model.restore(_:)`, `model.dismiss(_:)`.
- Produces: no new interfaces — view-internal changes only.

- [ ] **Step 1: Rework the EarlierSection header**

In `EarlierSection.body`, replace the header `HStack` (the `Text("EARLIER")` … `Restore all` button block, lines 298–312) with:

```swift
HStack(spacing: 6) {
    Text("EARLIER")
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(Theme.textTertiary)
    // "Restore all" earns its place only when there is more than one thing to restore;
    // inline with the label so it never stacks over the rows' own Restore buttons.
    if model.restorables.count > 1 {
        Text("·")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
        Button(action: { model.restoreAll() }) {
            Text("Restore all")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Restore every previous session")
    }
    Spacer()
}
.padding(.horizontal, 4)
.padding(.bottom, 4)
```

Also update `EarlierSection`'s doc comment: the header shows "Restore all" inline only with 2+ sessions.

- [ ] **Step 2: Use endedLabel in RestorableRow**

In `RestorableRow` (line 334), delete the `relativeFormatter` static and the `endedText` computed property (lines 341–350), and replace the body's `if let endedText` usage with:

```swift
if let endedText = session.endedLabel(now: Date()) {
```

- [ ] **Step 3: Build and run all tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds, full suite passes (85 tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/linkc/PanelView.swift
git commit -m "Move Restore all inline into the EARLIER header, shown only with 2+ sessions"
```

---

### Task 3: Empty state becomes the launcher; header + hides while it shows

**Files:**
- Modify: `Sources/linkc/PanelView.swift` (`PanelView.body` ~line 22, `PanelHeader` lines 70–93, `EmptyStateView` lines 537–562)

**Interfaces:**
- Consumes: existing `model.newSession(mode:)` with `.new` / `.continueLast` / `.resume`; `Theme.hoverEase`, `Theme.viewSwap`, `Theme.textSecondary`, `Theme.textTertiary`; `StatusDot`, `PrimaryButtonStyle`.
- Produces: `PanelHeader(model:showsLauncher:)` (new `let showsLauncher: Bool` property); private `QuietLink` view used only within `PanelView.swift`.

- [ ] **Step 1: Hide the launcher while the empty state shows**

In `PanelView.body`, change `PanelHeader(model: model)` (line 22) to:

```swift
// The + hides while the empty state shows — the empty state is the launcher then,
// and two launch affordances never share the screen.
PanelHeader(
    model: model,
    showsLauncher: model.selectedId != nil
        || !model.sessions.isEmpty
        || !model.restorables.isEmpty
)
```

In `PanelHeader`, add the property under `let model: AppModel`:

```swift
let showsLauncher: Bool
```

wrap the launcher (line 84) as:

```swift
if showsLauncher {
    LauncherMenu(model: model)
        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
}
```

and add alongside the header's existing `.animation` modifiers:

```swift
.animation(Theme.viewSwap, value: showsLauncher)
```

- [ ] **Step 2: Rewrite EmptyStateView as the launcher**

Replace `EmptyStateView` (lines 537–562) with:

```swift
/// The launcher: while nothing exists the panel's one entry point is here, not the chrome —
/// the header + is hidden. Primary New session, quiet Continue/Resume beneath, and (since the
/// + menu is gone) a faint quit link in the corner.
private struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            // The signature dot as the hero, in its waiting state: linkC itself is waiting
            // for input. Pulses like a needs-you card would (Reduce Motion: steady glow).
            StatusDot(state: .waitingIdle)
                .scaleEffect(1.6)
            Text("No sessions yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Button("New session") { model.newSession(mode: .new) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            HStack(spacing: 6) {
                QuietLink("Continue last") { model.newSession(mode: .continueLast) }
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                QuietLink("Resume…") { model.newSession(mode: .resume) }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            QuietLink("quit linkC", size: 10) { NSApplication.shared.terminate(nil) }
                .padding(12)
        }
    }
}

/// A small muted text action — tertiary grey that warms to secondary on hover.
private struct QuietLink: View {
    let title: String
    let size: CGFloat
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, size: CGFloat = 11, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size))
                .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.hoverEase, value: hovering)
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 3: Build and run all tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds, full suite passes.

- [ ] **Step 4: Commit**

```bash
git add Sources/linkc/PanelView.swift
git commit -m "Make the empty state the launcher; hide the header + while it shows"
```

---

### Task 4: Verify in the real app

**Files:** none (build & swap).

- [ ] **Step 1: TSan pass**

Run: `scripts/tsan.sh 2>&1 | tail -3`
Expected: full suite passes under thread sanitizer.

- [ ] **Step 2: Rebuild the app bundle**

Run: `./build-app.sh`
Expected: `dist/linkC.app` rebuilt without errors.

- [ ] **Step 3: Swap the running app — only if no live sessions**

```bash
pgrep -f "dist/linkC.app/Contents/MacOS/linkC" | head -1
# For the found PID: pgrep -P <pid> — if it prints anything, a session is live: STOP and
# ask the user before quitting. If empty:
osascript -e 'tell application "linkC" to quit'
open dist/linkC.app
```

- [ ] **Step 4: Visual check**

Ask the user to open the panel and confirm: empty state shows dot / title / New session / `Continue last · Resume…` / corner `quit linkC` with no header `+`; with a restorable present the `+` returns and a single Earlier row shows only its own Restore.
