# linkc-agents

A Claude Code mod that splits the [filetree](https://github.com/data-goblin/claude-code-filetree) pane in two:
the file tree in the top half, and linkC's sessions in the session's repo in the bottom half.

Each session is a card: its title, then what it is doing and for how long. A bar down the card's
left edge is the agent's color. Sessions that need you (a permission, a question, an error) sort
first and show in orange, and the header counts them. Your own session is marked `you`; a session
linkC started for a delegated task is marked `worker`.

A session is in the repo when it runs in the repo's folder, a folder below it, or a worktree inside
it (`.worktrees/…`). The repo is the one the Claude Code session's folder belongs to, found with
`git rev-parse --git-common-dir`; a folder outside git counts as its own repo.

## The usage band

Above the prompt, one box holds a meter for the context and one for each plan limit (`5h`, `7d`):
the label, an 8-cell bar and the percent, padded so the columns stay put as the numbers change.
A bar turns orange from 70% and red from 90%. The context counts against the point where the
session auto-compacts, as `/context` does. Beside the box, **Compact** (or `0` typed into an empty
prompt) runs `/compact`; it hides while a turn runs. The meters refresh when the session starts,
when the engine measures usage, and at the end of each turn.

The skins mod draws its own usage band; turn it off with `/skin band off` so only one shows.

## How it works

linkC writes its live sessions to `~/Library/Application Support/linkC/projects.json`. The mod reads
that file every 2 seconds and redraws when it changes, and once a minute for the ages. A linkC
older than the row details (title, state, action) shows each session's agent and `idle` or `busy`.
If the file cannot be read, the panel says why instead of showing no sessions.

The mod draws nothing of its own until filetree's pane is open: open it with `/filetree`.

## Install

linkC installs this mod to `~/Library/Application Support/linkC/mods/linkc-agents` on launch.
Load that folder for every session through `env` in `~/.claude/settings.json`. Separate several
folders with `:`.

```json
{
  "env": {
    "CLAUDE_CODE_PLUGIN_DIRS": "~/Library/Application Support/linkC/mods/linkc-agents"
  }
}
```

Restart Claude Code sessions afterwards.

## Develop

```sh
claude plugin validate mods/linkc-agents
claude plugin test mods/linkc-agents
```
