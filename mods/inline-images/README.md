# inline-images

A Claude Code mod that draws pictures in the chat. When the agent reads an image file, or sends you
a message or file with an image attached, the picture is drawn under that row instead of an
`[image] path (size)` line. A run of reads folded into one `Read N files` line unfolds when it holds
a picture, so each one shows.

`/images off` hides the pictures, `/images on` brings them back, and `/images` alone switches. The
choice is kept across sessions.

## How it works

A picture is drawn with the terminal surface's `Image` element, which takes PNG bytes up to 2 MiB.
A PNG under that size is drawn as it is. Anything else (JPEG, HEIC, WebP, a bigger PNG) is converted
with macOS's `sips`, its longest side at 1600 px and then smaller until it fits, and kept in the
mod's data folder, so the next draw reads it from there. A picture that cannot be converted shows a
red line under its row saying why.

The picture is as wide as the terminal allows, up to 120 columns and one column per 8 px, and at
most 40 rows tall.

Claude Code draws pictures only in a terminal it knows can (kitty, Ghostty, iTerm2 3.5 or later),
or where `CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1` is set, as linkC's terminals do. Elsewhere it shows a
dim line saying the terminal can't draw pictures.

## Install

linkC installs this mod to `~/Library/Application Support/linkC/mods/inline-images` on launch.
Load that folder for every session through `env` in `~/.claude/settings.json`, beside any other
mod folders, separated by `:`.

```json
{
  "env": {
    "CLAUDE_CODE_PLUGIN_DIRS": "~/Library/Application Support/linkC/mods/linkc-agents:~/Library/Application Support/linkC/mods/inline-images"
  }
}
```

Restart Claude Code sessions afterwards.

## Develop

```sh
claude plugin validate mods/inline-images
claude plugin test mods/inline-images
```
