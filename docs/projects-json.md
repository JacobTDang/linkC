# `projects.json`

linkC writes `~/Library/Application Support/linkC/projects.json` while it runs, and removes it when
it quits. Its MCP servers read it to reach other projects, and panels draw cards from it (the
`linkc-agents` mod, and linkC's own native cards). linkC rewrites it in one step whenever its
contents change.

Every field after `id`, `agent` and `activity` is optional: a file an older linkC wrote has none of
them, and a field is absent when linkC knows nothing for it. A reader must draw what is there and
ignore keys it does not know.

```json
{
  "projects": [
    {
      "path": "/canonical/folder",
      "sessions": [
        {
          "id": "linkC session id",
          "agent": "codex",
          "activity": "busy",
          "title": "What its row shows",
          "state": "working",
          "since": "2026-11-24T18:00:00Z",
          "model": "model id",
          "worker": true,
          "action": "The action line its row reads",
          "subagents": 2,
          "cacheExpiresAt": "2026-11-24T18:30:00Z",
          "cacheEstimate": true,
          "contextPercent": 41,
          "step": "$ swift test",
          "subagentSteps": [{ "name": "Survey the readers", "step": "⊙ Card.swift" }]
        }
      ]
    }
  ],
  "limits": {
    "codex": [{ "label": "5h", "percent": 72, "resets": "2026-11-24T20:00:00Z" }]
  }
}
```

## A session

| Field | Meaning |
|---|---|
| `id` | linkC's id for the session. |
| `agent` | The agent kind: `claude`, `codex`, `agy`, `cursor`, `grok`, `opencode`, `kilo`, `crush`, `freebuff`, or one a newer linkC knows. |
| `activity` | `idle`, `busy` or `starting`. |
| `title` | What the session's sidebar row shows. |
| `state` | linkC's finer state: `starting`, `ready`, `working`, `waitingPermission`, `waitingIdle`, `finished`, `error`. |
| `since` | When `state` began, ISO 8601. |
| `model` | The model it runs now where its agent reports one, else the model it was launched on. |
| `worker` | linkC started it to carry a delegated task. |
| `action` | Its row's action line: the agent's own record of the step where linkC has one, else read off its screen. Only while it works or waits on a permission. |
| `subagents` | How many subagents it runs now. |
| `cacheExpiresAt`, `cacheEstimate` | When its prompt cache goes cold; `cacheEstimate` when that is worked out from the provider's cache lifetime rather than reported. |
| `contextPercent` | How full its context is, 0–100, of the context window, as its agent reports it. |
| `step` | The step its running turn is on, as the agent's own hooks or files record it (never a screen read). Only while it works or waits on a permission. |
| `subagentSteps` | Each running subagent, by the name it was started with, and the `step` its own files record (absent when they record none yet). Shown at rest too: a session whose own turn ended can still run them. |

## Limits

`limits` holds each agent's plan limits, keyed by agent kind. Each is `label` (the window, such as
`5h` or `7d`), `percent` used (0–100) and `resets` (ISO 8601, absent when the agent does not say).
Only a reading taken within the last hour is listed, and only its windows that give a percent and
have not reset.

## Where each agent's figures come from

| Agent | `contextPercent` | `step` | `subagentSteps` | `limits` |
|---|---|---|---|---|
| Claude Code | Its status line's `context_window.used_percentage` | Its transcript's newest tool call | Each subagent's own transcript in `<session>/subagents/` | Its status line's `rate_limits` |
| Codex | Its rollout's newest `token_count`: the last request's tokens against `model_context_window`, each less the 12,000 tokens Codex counts as always there, as its own footer shows it | Its rollout's last tool call in the running turn | none recorded | Its rollouts' `rate_limits` |
| Cursor, Grok | Its chat store (`chats/<md5 of folder>/<chat>/store.db`): the root blob's used tokens against its window | Its transcript's last tool call after the last user line, until `turn_ended` | none: its transcripts record no tool results, so a subagent's end can't be told | none exposed |
| agy | Its conversation database's newest `gen_metadata` row: tokens used against the window | none exposed | none exposed | not polled: `agy -p "/usage"` reports them, but each run writes agy's history and starts its MCP servers |
| OpenCode | Its database's newest request in the conversation linkC opened: input, output, reasoning and both cache counts, against the model's `limit.context` in its `models.json` | none: an in-flight tool's state is not confirmed | none | none exposed |
| Kilo | none: linkC passes Kilo no conversation id, so a session can't be tied to its record exactly | none | none | none exposed |
| Crush | none: its records could not be checked against a real session | none | none | none exposed |
| Freebuff | none: it records tokens used but not the window | none: it records a step only once the step ends | none | none exposed |

Each session is tied to its own record exactly, never by folder or start time alone: Codex's by the
rollout its process holds open, Cursor's and Grok's by the chat store theirs holds open, agy's by
the presence lock its process holds, which names the conversation, and OpenCode's by the
conversation id linkC passes it.
