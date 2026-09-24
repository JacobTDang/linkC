# Terminal follows its folder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a plain terminal's name, and its project, follow the folder its shell is in after a `cd`.

**Architecture:**
- Once a second, the existing shell sweep asks the kernel for each running shell's current folder (`proc_pidinfo(PROC_PIDVNODEPATHINFO)`).
- `ShellTerminalStore.updateDirectory` moves the row. A plain terminal is renamed through the pure `ShellTitle` rule.
- `ShellCoordinator.sampleDirectories` writes the new folder to `shells.json`.
- The sidebar, the tab strip and the project rule already read `row.cwd` and `row.title`, so they follow with no changes.

**Tech Stack:** Swift 6, macOS 14, SwiftPM, XCTest, Darwin `libproc`.

Spec: `docs/superpowers/specs/2026-09-24-terminal-follows-folder-design.md`.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/terminal-folder`, branch `feat/terminal-follows-folder`. Never touch `/Users/jacobdang/Projects/linkC` itself or any other `.worktrees` folder.
- **Where the logic lives:** in LinkCKit, unit-tested there. The `linkc` app target only calls it.
- **Test-first:** write the test, see it FAIL on an assertion (stub first, so it's never a compile error), implement, and see it pass.
- **Fail loud:** no swallowed errors. Log with format arguments, e.g. `NSLog("… %@", value)`; never interpolate text into a format string.
- **No new dependencies.** No SwiftUI view body may write state.
- **Build:** `swift build 2>&1 | tail -1`. The command `swift build --build-tests 2>&1 | grep -E "warning:"` must print nothing.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures. Main is at 1385 tests.
- **Commits:**
  - one commit per task, with a one-line message starting `feat(terminals): `;
  - stage files by name, never `git add -A` or `git add .`;
  - no trailers of any kind;
  - "claude" must never appear in a message, in any case.

---

### Task 1: A terminal's folder and name can change

**Files:**
- Create: `Sources/LinkCKit/Terminal/ShellTitle.swift`
- Modify: `Sources/LinkCKit/Terminal/ProcessSnooper.swift` (add `currentDirectory(ofPid:)` after `parentPid(of:)`)
- Modify: `Sources/LinkCKit/Terminal/ShellTerminalStore.swift` (`ShellRow.cwd`/`title` become settable in-module; add `updateDirectory`)
- Modify: `Sources/LinkCKit/Terminal/ShellCoordinator.swift` (`launch`'s default title uses `ShellTitle`)
- Test:
  - Create: `Tests/LinkCKitTests/ShellTitleTests.swift`
  - Modify: `Tests/LinkCKitTests/ProcessSnooperTests.swift`, `Tests/LinkCKitTests/ShellTerminalStoreTests.swift`, `Tests/LinkCKitTests/SidebarModelTests.swift`, `Tests/LinkCKitTests/ShellCoordinatorTests.swift`

**Interfaces:**
- Produces:
  - `public enum ShellTitle { public static func name(forDirectory directory: String, home: String) -> String }`
  - `ProcessSnooper.currentDirectory(ofPid pid: pid_t) -> String?`
  - `ShellRow.cwd` and `ShellRow.title` are `public internal(set) var`
  - `@discardableResult public func updateDirectory(id: String, to directory: String, home: String = NSHomeDirectory()) -> ShellRow?` on `ShellTerminalStore`

- [ ] **Step 1: Stub the new API so the tests compile.**

`Sources/LinkCKit/Terminal/ShellTitle.swift`:
```swift
import Foundation

/// The name a plain terminal shows for the folder it is in.
public enum ShellTitle {
    /// "~" for `home`, "/" for the root, otherwise the folder's last path component.
    public static func name(forDirectory directory: String, home: String) -> String {
        ""
    }
}
```

In `ProcessSnooper.swift`, directly after `parentPid(of:)`:
```swift
    /// The process's current folder via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, as the kernel
    /// reports it (symlinks resolved, e.g. `/private/tmp`). Nil for invalid pids or when the
    /// kernel refuses (a process that is gone, or one owned by another user).
    public static func currentDirectory(ofPid pid: pid_t) -> String? {
        nil
    }
```

In `ShellTerminalStore.swift`, change `ShellRow`'s two properties:
```swift
    public let id: String
    public internal(set) var cwd: String
    public internal(set) var title: String
```
and add to `ShellTerminalStore`, after `updateDetectedAgent`:
```swift
    /// Moves a row to the folder its shell is now in. A plain terminal (no command) is renamed
    /// after the folder; a command terminal keeps its title. Writes only on a real change,
    /// because the sweep runs every second, and returns the updated row, or nil when nothing
    /// changed.
    @discardableResult
    public func updateDirectory(id: String, to directory: String, home: String = NSHomeDirectory()) -> ShellRow? {
        nil
    }
```

- [ ] **Step 2: Write the failing tests.**

`Tests/LinkCKitTests/ShellTitleTests.swift`:
```swift
import XCTest
@testable import LinkCKit

final class ShellTitleTests: XCTestCase {
    func testHomeShowsAsTilde() {
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j", home: "/Users/j"), "~")
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j/", home: "/Users/j"), "~")
    }

    func testRootShowsAsSlash() {
        XCTAssertEqual(ShellTitle.name(forDirectory: "/", home: "/Users/j"), "/")
    }

    func testAFolderShowsItsLastComponent() {
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j/Projects/linkC", home: "/Users/j"), "linkC")
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j/Projects/linkC/", home: "/Users/j"), "linkC")
    }
}
```

Append inside `ProcessSnooperTests` (before its closing `}`):
```swift
    func testCurrentDirectoryReadsALiveProcessesFolder() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cd /tmp && exec sleep 5"]
        try process.run()
        defer { process.terminate() }

        var seen: String?
        for _ in 0..<100 {
            seen = ProcessSnooper.currentDirectory(ofPid: process.processIdentifier)
            if seen == "/private/tmp" { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(seen, "/private/tmp", "the kernel reports the resolved folder")
    }

    func testCurrentDirectoryIsNilForAPidThatDoesNotExist() {
        XCTAssertNil(ProcessSnooper.currentDirectory(ofPid: 0))
        XCTAssertNil(ProcessSnooper.currentDirectory(ofPid: pid_t(Int32.max)))
    }
```

Append inside `ShellTerminalStoreTests` (before its closing `}`):
```swift
    func testAPlainTerminalTakesItsNewFoldersName() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j/Projects/linkC", title: "linkC")

        let updated = store.updateDirectory(id: "T1", to: "/Users/j/Projects/linkC/Sources", home: "/Users/j")
        XCTAssertEqual(updated?.cwd, "/Users/j/Projects/linkC/Sources")
        XCTAssertEqual(updated?.title, "Sources")
        XCTAssertEqual(store.row(id: "T1"), updated)

        XCTAssertEqual(store.updateDirectory(id: "T1", to: "/Users/j", home: "/Users/j")?.title, "~")
    }

    func testACommandTerminalKeepsItsTitle() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j", title: "logs: web", command: "docker logs -f web")

        let updated = store.updateDirectory(id: "T1", to: "/tmp", home: "/Users/j")
        XCTAssertEqual(updated?.cwd, "/tmp")
        XCTAssertEqual(updated?.title, "logs: web")
    }

    func testTheSameFolderChangesNothing() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j/Projects/linkC", title: "linkC")

        XCTAssertNil(store.updateDirectory(id: "T1", to: "/Users/j/Projects/linkC", home: "/Users/j"))
        XCTAssertNil(store.updateDirectory(id: "missing", to: "/tmp", home: "/Users/j"))
    }

    func testAnOldNameIsCorrectedInPlace() {
        // A terminal restored with a name saved by an older linkC ("j" for the home folder).
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j", title: "j")

        XCTAssertEqual(store.updateDirectory(id: "T1", to: "/Users/j", home: "/Users/j")?.title, "~")
    }
```

Append inside `SidebarModelTests` (before its closing `}`):
```swift
    @MainActor
    func testATerminalThatChangesFolderFollowsTheFolderRuleUnlessFiled() {
        let store = ShellTerminalStore()
        store.add(id: "s1", cwd: "/Users/j", title: "~")
        store.add(id: "s2", cwd: "/Users/j", title: "~")
        store.updateDirectory(id: "s1", to: "/p/linkc", home: "/Users/j")
        store.updateDirectory(id: "s2", to: "/p/linkc", home: "/Users/j")

        let out = SidebarModel.projects(
            inputs: [input("session1", cwd: "/p/linkc"), input("session2", cwd: "/p/june")],
            shells: store.rows,
            filed: ["s2": "/p/june"],
            order: ["/p/linkc", "/p/june"],
            expandOverrides: [:],
            selectedId: nil
        )

        XCTAssertEqual(out.projects.map(\.path), ["/p/linkc", "/p/june"])
        XCTAssertEqual(out.projects[0].terminals.map(\.id), ["s1"])
        XCTAssertEqual(out.projects[0].terminals.map(\.title), ["linkc"])
        XCTAssertEqual(out.projects[1].terminals.map(\.id), ["s2"], "a filed terminal stays where it was filed")
        XCTAssertTrue(out.unfiled.isEmpty)
    }
```

Append inside `ShellCoordinatorTests` (before its closing `}`):
```swift
    func testAPlainShellInTheHomeFolderIsNamedTilde() throws {
        let coordinator = makeCoordinator(shell: "/bin/cat")
        let row = try coordinator.launch(cwd: NSHomeDirectory())
        XCTAssertEqual(row.title, "~")
    }
```

- [ ] **Step 3: Run the tests and see them fail on assertions.**

Run: `swift test --filter "ShellTitleTests|ProcessSnooperTests|ShellTerminalStoreTests|SidebarModelTests|ShellCoordinatorTests" 2>&1 | grep -E "error: -\[|Executed [0-9]+ test" | tail -20`

Expected: FAIL. The failing tests are all of `ShellTitleTests`, `testCurrentDirectoryReadsALiveProcessesFolder`, the four new store tests, the new sidebar test and `testAPlainShellInTheHomeFolderIsNamedTilde`. `testCurrentDirectoryIsNilForAPidThatDoesNotExist` passes against the `nil` stub, and that's expected. Keep the red lines for the report.

- [ ] **Step 4: Implement.**

`ShellTitle.name`:
```swift
    public static func name(forDirectory directory: String, home: String) -> String {
        let path = (directory as NSString).standardizingPath
        if path == (home as NSString).standardizingPath { return "~" }
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }
```

`ProcessSnooper.currentDirectory`:
```swift
    public static func currentDirectory(ofPid pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard got == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
```

`ShellTerminalStore.updateDirectory`:
```swift
    public func updateDirectory(id: String, to directory: String, home: String = NSHomeDirectory()) -> ShellRow? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        var row = rows[index]
        row.cwd = directory
        if row.command == nil {
            row.title = ShellTitle.name(forDirectory: directory, home: home)
        }
        guard row != rows[index] else { return nil }
        rows[index] = row
        return row
    }
```

In `ShellCoordinator.launch`, replace
`let title = title ?? URL(fileURLWithPath: cwd).lastPathComponent`
with
`let title = title ?? ShellTitle.name(forDirectory: cwd, home: NSHomeDirectory())`.

- [ ] **Step 5: Run the tests and see them pass.**

Run: the Step 3 command. Expected: every test passes, 0 failures.
Then: `swift build --build-tests 2>&1 | grep -E "warning:"` prints nothing, and the full suite reports 0 failures.

- [ ] **Step 6: Commit.**

```bash
git add Sources/LinkCKit/Terminal/ShellTitle.swift Sources/LinkCKit/Terminal/ProcessSnooper.swift Sources/LinkCKit/Terminal/ShellTerminalStore.swift Sources/LinkCKit/Terminal/ShellCoordinator.swift Tests/LinkCKitTests/ShellTitleTests.swift Tests/LinkCKitTests/ProcessSnooperTests.swift Tests/LinkCKitTests/ShellTerminalStoreTests.swift Tests/LinkCKitTests/SidebarModelTests.swift Tests/LinkCKitTests/ShellCoordinatorTests.swift
git commit -m "feat(terminals): a terminal's folder can change, and a plain one is named after it"
```

---

### Task 2: The shell sweep follows each shell into its folder

**Files:**
- Modify: `Sources/LinkCKit/Terminal/ShellCoordinator.swift` (add `sampleDirectories()` next to `sampleAgents()`)
- Modify: `Sources/linkc/LinkCApp.swift`: rename `sampleShellAgents()` to `sampleShells()`, which calls `sampleDirectories()` first. Its only caller is in `startShellSweep()`.
- Test: `Tests/LinkCKitTests/ShellCoordinatorTests.swift` (the `ShellPersistenceTests` class)

**Interfaces:**
- Consumes (Task 1): `ProcessSnooper.currentDirectory(ofPid:)`, `ShellTerminalStore.updateDirectory(id:to:home:)`, `ShellTitle`
- Produces: `public func sampleDirectories()` on `ShellCoordinator`

- [ ] **Step 1: Stub.**

In `ShellCoordinator`, directly after `sampleAgents()`:
```swift
    /// Follows each running shell into the folder it is now in after a `cd`. The row's folder,
    /// and a plain terminal's name, update, and the manifest remembers the new folder so a
    /// restore reopens there. Runs from the one-second shell sweep.
    public func sampleDirectories() {}
```

- [ ] **Step 2: Write the failing test.**

Append inside `ShellPersistenceTests` (before its closing `}`):
```swift
    func testAShellThatChangesFolderIsRenamedAndRememberedThere() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminals = TerminalSessionManager()
        defer { for session in terminals.sessions { terminals.terminate(session.id) } }
        let coordinator = ShellCoordinator(terminals: terminals, manifestDir: dir, shellPath: { "/bin/sh" })

        let row = try coordinator.launch(cwd: "/tmp")
        terminals.sendInput(sessionId: row.id, text: "cd /usr")
        for _ in 0..<150 {
            coordinator.sampleDirectories()
            if coordinator.store.row(id: row.id)?.cwd == "/usr" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(coordinator.store.row(id: row.id)?.cwd, "/usr")
        XCTAssertEqual(coordinator.store.row(id: row.id)?.title, "usr")
        let entry = try XCTUnwrap(ShellManifest(directory: dir).entries.first { $0.id == row.id })
        XCTAssertEqual(entry.cwd, "/usr", "a restore reopens where the shell was left")
        XCTAssertEqual(entry.title, "usr")
    }
```

- [ ] **Step 3: Run it and see it fail on an assertion.**

Run: `swift test --filter "ShellPersistenceTests/testAShellThatChangesFolderIsRenamedAndRememberedThere" 2>&1 | grep -E "error: -\[|Executed [0-9]+ test" | tail -4`
Expected: FAIL. Against the stub, `cwd` stays "/tmp". Keep the red line.

- [ ] **Step 4: Implement.**

Replace the stub with:
```swift
    /// Ids whose folder read failed and was logged. Cleared on the next successful read, so a
    /// failure is logged once, not every second.
    private var unreadableDirectories: Set<String> = []

    /// Follows each running shell into the folder it is now in after a `cd`. The row's folder,
    /// and a plain terminal's name, update, and the manifest remembers the new folder so a
    /// restore reopens there. Runs from the one-second shell sweep.
    public func sampleDirectories() {
        for row in store.rows where row.state == .running {
            guard let terminal = terminals.session(id: row.id), terminal.isRunning, terminal.processId > 0 else { continue }
            guard let raw = ProcessSnooper.currentDirectory(ofPid: terminal.processId) else {
                if unreadableDirectories.insert(row.id).inserted {
                    NSLog("[linkC] shell %@: could not read the folder of pid %d", row.id, terminal.processId)
                }
                continue
            }
            unreadableDirectories.remove(row.id)
            let directory = (raw as NSString).standardizingPath
            guard let updated = store.updateDirectory(id: row.id, to: directory) else { continue }
            manifest?.upsert(RestorableShell(
                id: updated.id,
                cwd: updated.cwd,
                title: updated.title,
                command: updated.command,
                wasActiveOnQuit: true,
                detectedAgent: updated.detectedAgent,
                endedAt: nil
            ))
        }
    }
```
(Keep the stored property with the class's other stored properties, at the top of `ShellCoordinator`.)

In `Sources/linkc/LinkCApp.swift`:
- rename `func sampleShellAgents()` to `func sampleShells()`, and make its first line `shells?.sampleDirectories()`, before `shells?.sampleAgents()`;
- in `startShellSweep()`, change `self?.sampleShellAgents()` to `self?.sampleShells()`.

- [ ] **Step 5: Run the test, the warnings check and the full suite.**

Run the Step 3 command; expected PASS.
Then `swift build 2>&1 | tail -1`. `swift build --build-tests 2>&1 | grep -E "warning:"` must print nothing, and the full suite must report 0 failures.
Also `grep -rn "sampleShellAgents" Sources` must print nothing.

- [ ] **Step 6: Commit.**

```bash
git add Sources/LinkCKit/Terminal/ShellCoordinator.swift Sources/linkc/LinkCApp.swift Tests/LinkCKitTests/ShellCoordinatorTests.swift
git commit -m "feat(terminals): the shell sweep follows each shell into its folder and remembers it"
```

---

## Hand checks (the running app)

- **Following the folder:** `cd` around in a plain terminal. The sidebar row and the tab strip rename within a second, and home shows "~".
- **Unfiled terminal:** `cd` into another project's folder, and it moves under that project.
- **Filed terminal:** it stays where it was filed and only renames.
- **Running a program:** start `claude` in the terminal; the name holds.
- **Quit and reopen:** the terminal reopens in the last folder.
