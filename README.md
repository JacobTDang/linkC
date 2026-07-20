# linkC

A macOS menu-bar app for running and managing multiple Claude Code sessions in one
place. Instead of a wall of terminal windows, each session is a tab in one dedicated
**kitty** window, and linkC tells you the moment a session **finishes** or **needs input**.

## How it works

linkC orchestrates a dedicated kitty window through kitty's remote-control protocol —
each session is a `claude` process in its own tab. It learns each session's state from
Claude Code **hooks**: every session is launched wired to a tiny local HTTP server, so
linkC gets structured lifecycle events (`Stop`, `Notification`, …) rather than scraping
terminal text. Each event carries the session's id in a header, giving a deterministic
map from event → tab. Notifications are focus-aware: you're only pinged when you aren't
already watching that session.

## Requirements

- macOS 14+
- [kitty](https://sw.kovidgoyal.net/kitty/) (`brew install kitty`)
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

A `▣` icon appears in the menu bar. Grant notification permission when asked. Use
**New session…** to pick a folder — linkC opens (or reuses) its kitty window and starts
`claude` there. Sessions show live status; click one to jump to its tab, or Stop it.

## Layout

- `Sources/LinkCKit/Core` — domain models, session state machine, observable store
- `Sources/LinkCKit/Kitty` — kitty remote-control driver + `ls` parser
- `Sources/LinkCKit/Hooks` — hook decoder, loopback HTTP server, settings composer
- `Sources/LinkCKit/Notify` — focus policy + notification delivery
- `Sources/LinkCKit/App` — the coordinator that wires it all together
- `Sources/linkc` — the SwiftUI menu-bar shell
