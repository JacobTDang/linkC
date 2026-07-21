# linkC

A macOS menu-bar app for running and managing multiple Claude Code sessions in one place.
Instead of a wall of terminal windows, each session runs in an **embedded terminal** inside a
panel that hangs off the menu-bar icon, and linkC tells you the moment a session **finishes**
or **needs input**.

## How it works

Each session runs `claude` in its own embedded [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
terminal, hosted in a `MenuBarExtra(.window)` panel — no external terminal app required. linkC
learns each session's state from Claude Code **hooks**: every session is launched wired to a
tiny local HTTP server, so linkC gets structured lifecycle events (`Stop`, `Notification`, …)
rather than scraping terminal text. Each event carries the session's id in a header, giving a
deterministic map from event → session. Notifications are focus-aware: you're only pinged when
you aren't already watching that session (panel open, linkC active, and its tab selected).

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
./build-app.sh           # produces dist/linkC.app (code-signed for notifications)
open dist/linkC.app      # launches the menu-bar app
```

A `▣` icon appears in the menu bar. Grant notification permission when asked. Click the icon to
open the panel, then use **New session…** to pick a folder — linkC starts `claude` in an
embedded terminal right there. Sessions show live status in the tab strip; click a tab to bring
its terminal on screen, or close it to stop the session.

## Layout

- `Sources/LinkCKit/Core` — domain models, session state machine, observable store
- `Sources/LinkCKit/Terminal` — embedded terminal session, manager, and SwiftUI host
- `Sources/LinkCKit/Hooks` — hook decoder, loopback HTTP server, settings composer
- `Sources/LinkCKit/Notify` — focus policy + notification delivery
- `Sources/LinkCKit/App` — the coordinator that wires it all together
- `Sources/linkc` — the SwiftUI menu-bar shell + panel
