# Model Choices: Live Model Lists, a Model per Task, and Limits per Pool

**Date:** 2026-11-11
**Status:** Approved design (branch `feat/model-choices`)

## 1. Problem

Jacob wants more choice of models, and he wants to use only what is free or already part of his plans. OpenCode must run on free models only.

His example: agy's Gemini weekly quota is at 0.13%, but agy's Claude/GPT quota is at 100%. He wants to use Claude Opus through agy. linkC cannot do this today, for three reasons:

- **Only Gemini models.** Each agent gets one model per tier (light, standard, deep). agy's tiers are all Gemini models. The deep tier's model, `gemini-3.1-pro-high`, is no longer offered by agy.
- **One limit for the whole agent.** A limit on any agy model marks all of agy as limited. `linkc_delegate_task` then refuses every agy task until the cooldown ends.
- **A stale built-in list.** `AgentModelCatalog` still offers GPT-4o and Claude 3.5. The in-app model switch (`AppCoordinator.switchModel`) checks against this list, so it refuses the models the agents really offer.

## 2. Goals

- linkC knows each agent's real models, from the agent's own CLI.
- In Settings, each tier is a picker of these models.
- Claude can delegate a task to a given model of an agent, not only to a tier.
- A limit on agy blocks only the quota pool it hit: either Gemini, or Claude/GPT.
- OpenCode offers and accepts free models only.
- A failure is reported immediately, with the reason: a model that does not exist, a model that is not free, or a model that is rate-limited. A failure never waits in a queue until the queue expires.

## 3. Non-goals

- **Falling back to another model automatically** when one model runs out. Jacob did not choose this.
- **Choosing a model in the panel's New menu.** Jacob did not choose this.
- **Reading agy's quota percentages.** agy shows them only in its interactive screen. linkC learns of a limit from the limit message in the terminal, as it does today.

## 4. Live model lists

### 4.1 Sources

| Agent | Source | Kept |
|---|---|---|
| agy | `agy models` (one `id<TAB>name` line per model, after a "Fetching…" line) | all |
| cursor | `cursor-agent models` (one `id - Name` line per model) | all |
| grok | Cursor's list | the ids that start with `grok-` |
| opencode | `opencode models --standalone` (one id per line) | free only: `opencode/*-free`, `opencode/big-pickle`, `ollama/*` (local) |
| claude | no list command | `haiku`, `sonnet`, `opus` |
| codex | no list command | `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-6-astra` (each was checked by hand with `codex exec --model`) |

For every agent, the ids set in its tiers are also listed, so a model typed in by hand still shows.

`ModelListParser` holds one pure function for each source. It turns the CLI's output into `[ListedModel(id, name)]`. `OpenCodeFreeModels.isFree(_:)` holds the OpenCode free rule. The existing OpenCode listing check (spec 2026-11-07) uses the same rule.

### 4.2 The cache

The app refreshes the lists at these times:

- at launch;
- every 6 hours;
- when Settings opens.

It saves them to `~/Library/Application Support/linkC/models.json`. For each agent the file holds:

- `models`;
- `fetchedAt`;
- `error`: nil, or the last failure's message.

A failed refresh keeps the last good list and records the error. Settings shows the error, and how old the list is. `MCPServer` reads the file and never runs a CLI to list models.

### 4.3 Settings

Each tier field becomes a picker of the agent's listed models. The picker also has "Other…", which opens a text field for an id that is not listed yet.

For OpenCode:

- the picker shows free models only;
- a typed id that is not free is refused, and the refusal is shown under the field.

### 4.4 `linkc_get_models`

For each agent, it returns:

- each model's id and name;
- the tier that uses the model, if one does;
- the model's agy pool (§6), for agy;
- how old the list is, and the last refresh error, if there is one.

### 4.5 Removing the old list

The hard-coded model list in `AgentModelCatalog`, and `isFreeOrSubscription`, are removed. `launchArguments` and `interactiveSwitchCommand` stay. `AppCoordinator.switchModel` checks against the live list.

## 5. A model for one task

`linkc_delegate_task` takes `model`, as an alternative to `tier`:

- **Both `tier` and `model`:** refused: "pass tier or model, not both".
- **A model that is not in the agent's list:** refused. The refusal lists the agent's models (§7).
- **OpenCode:** the model must also be free.

`TaskRecord` gets `model: String?`. A task with a model has no `tier`.

`Session.canCarry(task)` also requires `session.model == task.model` when the task has a model. If no session runs that model, `WorkerClaims` starts a worker, and the worker launches with that model (`launchArguments(model:for:)`). Tier tasks are unchanged.

A task with a model is never moved to another agent: its model means nothing to another agent. If its pool is limited, the task waits until the limit ends, and the delegator is told at once (§7).

`linkc_switch_model` checks against the live list and the pool limits, and refuses in the same way.

## 6. Limits per pool for agy

`AgentLimitStatus` gets `pool: String?`. Nil means the whole agent, which is what every limit written before this change means.

`ModelPool.pool(of:agent:)`:

- **For agy:**
  - `gemini-…` → `"gemini"`;
  - `claude-…` and `gpt-oss-…` → `"claude-gpt"`. This follows agy's own "Models & Quota" screen, which groups Claude Opus, Claude Sonnet and GPT-OSS together.
  - Any other agy id → nil (the whole agent).
- **Every other agent:** nil. Their quota covers the whole account.

When `recordLimit(of:)` sees a limit on an agy session, it records the limit for the pool of `session.model`.

`isAgentLimited(agent:model:)` replaces `isAgentLimited(agent:)`. A limit applies to a model when:

- the limit's pool is nil, or
- the limit's pool equals the model's pool.

The checks that have no model use the model of the task's tier.

When a tier task is moved to another agent because of a limit, the move still uses a limit that applies to the tier's model. So a Gemini limit no longer moves an agy task whose tier runs a Claude model.

## 7. Failures are reported immediately

Every failure below is reported at once, to the session that asked. None of them waits in a queue.

- **A model that does not exist.** `linkc_delegate_task`, `linkc_switch_model` and Settings refuse any model that is not in the agent's list. The refusal lists the agent's models.
- **A model that is not free (OpenCode).** These are refused, and the refusal lists the free models.
- **A model that is rate-limited.**
  - When the task is created or the model is switched, the refusal gives the reason and when the limit ends. It also names what is not limited. For example: "agy's Gemini pool is limited until Fri 09:12. Not limited: agy's Claude/GPT pool (claude-opus-4-6-thinking, claude-sonnet-4-6, gpt-oss-120b-medium), cursor, opencode."
  - When a worker already holding a task hits the limit, the delegator gets a notice at once. The existing reroute and the existing notices still apply.
- **A CLI that rejects its model at launch.** A worker started for a task with a model can end while it is still `.starting`. In that case the task fails at once, with the reason: "<Agent> exited at launch with model <id>: <the last non-empty line of its screen>". The task is not started again on every pass until the queue expires.

agy's "model not recognized" line at start-up is not a failure. It is a known warning that does no harm.

## 8. Testing

TDD through the existing seams. No real CLI is run in tests.

- **`ModelListParser`:** the real output shapes recorded in §4.1. These include the "Fetching…" header, the "Available models" header, blank lines, and the zero-width characters in Cursor's names.
- **`OpenCodeFreeModels.isFree`:** free ids and paid ids.
- **`ModelPool`:** each agy family, and every other agent.
- **The cache:**
  - a round trip;
  - a failed refresh keeps the last list and records the error;
  - the 6-hour schedule.
- **MCP:**
  - `linkc_get_models` output;
  - `linkc_delegate_task(model:)`: accepted, unknown, not free, both tier and model, pool-limited (and the refusal names what is not limited);
  - `linkc_switch_model` against the live list.
- **Relay:**
  - a task with a model goes only to a session running that model, and otherwise starts a worker with `--model`;
  - an agy Gemini limit does not hold a task for `claude-opus-4-6-thinking`;
  - a worker that ends while `.starting`, for a task with a model, fails that task at once with the reason.
- **Settings:** the picker lists the cached models, "Other…" accepts a typed id, and OpenCode refuses an id that is not free.
- **Full runs:** the full suite and `scripts/tsan.sh`.
