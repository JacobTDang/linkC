# linkC

A macOS menu-bar app for running and managing multiple Claude Code sessions in one place.
Instead of a wall of terminal windows, each session runs in an **embedded terminal** inside a
frosted panel that hangs off the menu-bar icon, and linkC tells you the moment a session
**finishes** or **needs input**.

## What it is

linkC lives in the menu bar (no Dock icon). Clicking the icon drops a dark, glass **panel**
into the top-right corner of the screen — a custom `NSStatusItem` + `NSPanel`, movable and
resizable, always clamped fully on-screen.

- **Embedded terminals.** Each session runs `claude` in its own
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) terminal, hosted right in the panel —
  no external terminal app required.
- **Home overview.** With no session selected, the panel shows every session as a compact card
  with a live preview of its recent terminal output (refreshed about once a second). Tap a card
  to bring that session's full terminal on screen; tap the back chevron to return.
- **Hook-driven state.** Every session is launched wired to a tiny local HTTP server, so linkC
  learns each session's lifecycle from Claude Code **hooks** (`SessionStart`, `UserPromptSubmit`,
  `Notification`, `Stop`, `SessionEnd`) rather than scraping terminal text. Each event carries the
  session's id in a header, giving a deterministic event → session map.
- **Attention at a glance.** The menu-bar icon turns **coral** whenever a session finishes or
  needs your input; a per-card status dot pulses coral for the same states.
- **Focus-aware notifications.** You're only pinged when you aren't already watching that session
  (panel open, linkC active, and its card selected). Clicking a notification opens the panel and
  focuses the session.
- **New / Continue / Resume.** Start a fresh session in a folder, `--continue` its most recent
  conversation, or `--resume` and pick a past session. These use Claude Code's own per-directory
  history, so they also reach sessions started outside linkC.
- **Warn on quit.** Quitting ends the `claude` processes linkC hosts, so it asks first when
  sessions are still running.

## Screenshots

<!-- screenshot: home overview -->
<!-- screenshot: session terminal -->

## Requirements

- macOS 14+
- [Claude Code](https://claude.com/claude-code) (`claude` on your PATH)

## Build & test

```sh
swift build      # compile
swift test       # run the unit + integration suite
```

## Run

```sh
./scripts/make-icon.sh   # render the app icon → Assets/linkC.icns (once, or after icon changes)
./build-app.sh --install # builds and installs /Applications/linkC.app
open /Applications/linkC.app
```

A stacked-layers icon appears in the menu bar. Grant notification permission when asked, then
click the icon to open the panel and use the **+** menu → **New session…** to pick a folder —
linkC starts `claude` in an embedded terminal right there.

The app is **ad-hoc signed**. On the machine that built it, `open` just works. Copied to another
Mac, the first launch is blocked by Gatekeeper — right-click the app → **Open** once to allow it.

## Layout

- `Sources/LinkCKit/Core` — domain models, session state machine, observable store
- `Sources/LinkCKit/Terminal` — embedded terminal session, manager, and SwiftUI host
- `Sources/LinkCKit/Hooks` — hook decoder, loopback HTTP server, settings composer
- `Sources/LinkCKit/Notify` — focus policy + notification delivery
- `Sources/LinkCKit/App` — the coordinator that wires it all together
- `Sources/linkc` — the menu-bar shell: status item, glass panel, home overview, terminal hero
- `scripts` — `render-icon.swift` + `make-icon.sh` render the app icon programmatically
