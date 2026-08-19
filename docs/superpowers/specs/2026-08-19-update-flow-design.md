# In-app update flow

## Goal

When a fresh build lands in the repo's `dist.noindex`, the running `/Applications/linkC.app`
offers "Update ready — Install & restart": one tap swaps the bundle and relaunches. No
network, no Sparkle — linkC is device-only by decision (2026-08-18).

## Detection

- `build-app.sh --install` additionally stamps `LinkCSourceDist` (the absolute path of the
  repo's `dist.noindex/linkC.app`) into the INSTALLED copy's Info.plist, so the running app
  knows where fresh builds land. Dev runs launched straight from dist have no such key and
  never check.
- Pure logic in `Sources/LinkCKit/App/UpdateCheck.swift`:
  `UpdateCheck.available(ownBuild: String, distBundle: URL) -> UpdateInfo?` reads the dist
  bundle's `Contents/Info.plist`; a present, readable plist whose `CFBundleVersion` differs
  from `ownBuild` yields `UpdateInfo(fromBuild:toBuild:)`. Missing or unreadable dist → nil,
  quietly (the user may have deleted the build products; that is not an error).
- `AppModel` polls on the existing usage timer (every 6th 5s tick, plus the first tick), only
  when the running bundle carries `LinkCSourceDist`. Result held as `updateAvailable`.

## The swap

- `UpdateSwap.script(pid:distPath:installPath:)` (same file) returns a shell script, pure and
  unit-testable: wait for `pid` to exit (`kill -0` poll), `ditto` dist → install path, `open`
  the installed app.
- `AppModel.installUpdate()`: writes the script to a temp file, launches it with `/bin/sh`
  via `Process` (children survive parent exit), sets `updateInProgress`, terminates the app.
- `AppDelegate.applicationShouldTerminate` returns `.terminateNow` when `updateInProgress` —
  tapping Install IS the consent; the quit-warning alert would be redundant.
- Sessions die into restorable cards through the existing manifest machinery; the user
  restores manually from EARLIER after relaunch (explicit decision — no auto-restore).
  Dev terminals are lost honestly, same as any quit.

## UI

One quiet strip on home, above the usage footer, styled like `ErrorBar` but accent-washed:
`Update ready · 886a672 → def4567` with an `Install & restart` accent button. Nowhere else.

## Testing

TDD in LinkCKitTests: `UpdateCheck.available` (differs / same / missing / unreadable plist,
via temp fixtures), `UpdateSwap.script` content (pid wait before ditto before open; paths
shell-quoted). The stamped plist key and the live swap are verified manually.

## Out of scope

Auto-restore after relaunch; update checks without the panel open; any network channel.
