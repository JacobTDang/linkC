# Current activity on session rows

## Goal

Session rows answer "what is Claude doing right now?" — the running command, the file
being edited, or the subagent in flight — in the empty space after the title (rail) and
after the path (home cards).

## Data

New pure parser `ActivityEvents` in `Sources/LinkCKit/Usage/`, fed the same transcript
lines `UsageTracker.refreshSession` already reads (hook events + the 5s panel timer).

- An assistant `tool_use` block sets the session's current activity:
  | tool | label |
  |---|---|
  | `Bash` | `$ <command, first line>` |
  | `Edit` / `Write` / `NotebookEdit` | `✎ <last path component of file_path>` |
  | `Read` | `⊙ <last path component>` |
  | `Agent` / `Task` | `▸ <description>` |
  | anything else | the bare tool name |
- A `tool_result` whose id matches the recorded activity clears it — thinking between
  tools shows nothing, never a stale command. A newer `tool_use` simply replaces.
- Sidechain lines (`isSidechain: true`) are skipped entirely: a subagent's inner Bash
  must not masquerade as the session's own action.
- Malformed blocks are skipped alone (same tolerance as `AgentEvents`).

State: `UsageTracker` holds a per-session current activity beside the agent assembler;
exposed as `sessionActivity(_ id:) -> String?` (the formatted label). It is cleared at
the same turn boundaries where agents are swept (prompt submit and turn end), so a new
turn never opens showing the previous turn's final action.

## Display

- **Rail (`CompactSessionRow`)**: after the title — system 11 monospaced,
  `Theme.textTertiary`, one line, tail-truncated. Shown only while
  `session.state.bucket == .active`; idle and needs-you rows stay as they are (the rail
  never states an absence). The title keeps layout priority; the activity truncates first.
- **Home cards (`HomeCard`)**: the same text in the header's middle, after the path,
  same gating and style. Path keeps its middle-truncation; activity yields to it.

## Testing

TDD in LinkCKitTests: parser cases (each tool mapping, result-clears, sidechain skipped,
malformed skipped, first-line-only for multiline commands), tracker exposure, and
clear-on-sweep via the existing coordinator harness.

## Out of scope

No PreToolUse hooks (would tax every tool call in real sessions for marginal freshness).
No activity in the mini-tab strip or Terminals rows.
