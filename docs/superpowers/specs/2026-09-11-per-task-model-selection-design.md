# Per-Task Model Selection: Tiers, Pinned Sessions, No Silent Fallback

**Date:** 2026-09-11
**Status:** Approved design, not yet implemented
**Depends on:** Delivery readiness fix (`4da5234`) on `main`

## 1. Problem

Every delegated task runs on whatever model its agent session happens to be on. In practice that is the agent's own default — `gpt-6-astra` for Codex — so a task that writes a one-line file costs the same as a task that designs a subsystem. linkC has no way to say "this one is routine".

The pieces that exist do not solve it:

- `AgentModelCatalog` is a hardcoded whitelist that has gone stale. It offers `gpt-4o`, `o3-mini` and `o1-mini` for Codex, none of which are current, and its `isFreeOrSubscription` check therefore *rejects* the models Codex actually runs.
- `linkc_switch_model` injects `/model <id>` into a live terminal. That mutates a session someone may be mid-conversation with, and it depends on terminal injection landing — the failure mode we just spent a fix on.

## 2. Goals

- A delegated task runs on a model chosen for that task, not on whatever the session defaulted to.
- Routine work goes to a cheap model with no thought from the delegator.
- Choosing a model is one setting per agent, editable when a provider renames its models — not a code change.
- A misconfiguration refuses the delegation with a message that names what is missing. It never quietly runs on the expensive model.

## 3. Non-goals

- Switching a running session's model. Sessions are pinned at launch and never mutated.
- Cost accounting or budgets. `ModelPricing` already exists for usage display and is untouched here.
- Choosing a tier automatically from the shape of the task. The delegator decides, or the agent default applies.
- Cursor. `cursor-agent` takes no model flag, so a tiered task for Cursor is refused (§9).

## 4. Tiers

Three tiers, and they are the only vocabulary delegation speaks:

```swift
public enum ModelTier: String, Codable, Sendable, CaseIterable {
    case light, standard, deep
}
```

A tier never names a raw model id. Providers rename models often, and a rate-limit reroute moves a task from one agent kind to another, where a literal id would be meaningless.

## 5. Settings own the mapping

`AppPreferences` gains two stored values, both UserDefaults-backed like the rest of that type:

- `modelForTier: [AgentKind: [ModelTier: String]]` — the model id launched for each tier.
- `defaultTier: [AgentKind: ModelTier]` — the tier a task gets when the delegator does not name one.

Seeded on first run with today's models, which is the only place they are written down. Only
ids verified against the real CLIs are seeded; an empty entry means that tier is unconfigured,
and delegation refuses loudly (§9) rather than launching a session pinned to a model nobody
confirmed works:

| Agent  | light                     | standard                     | deep                     | default  |
|--------|---------------------------|-------------------------------|--------------------------|----------|
| claude | haiku                     | sonnet                        | opus                     | standard |
| codex  | gpt-5.6-luna              | gpt-5.6-sol                   | gpt-6-astra              | standard |
| agy    | gemini-3.8-flash-low      | gemini-3.8-flash-medium       | gemini-3.1-pro-high      | standard |

Every id above was confirmed against the real CLI. `gpt-6-sol` and `gpt-6-luna` were tried first
and came back HTTP 400 ("not supported when using Codex with a ChatGPT account"); the working
spellings are `gpt-5.6-sol` and `gpt-5.6-luna`. Codex validates nothing locally, so a wrong id does
not fail fast — it starts a session that then fails every request. That is why an id is only seeded
once a live run has answered on it, and why an unconfirmed tier is left empty rather than guessed:
codex's `light` and `standard` tiers ship empty; the settings fields exist precisely so a real id
for either can be typed in as a one-line edit, and §9 refuses rather than guesses in the meantime.
`agy models` lists the agy ids above verbatim, so they need no such caveat.

A Models section in `SettingsScreen` renders one row per agent kind with three model fields and a default-tier picker. Each field is free text with the known ids as suggestions — a renamed model must be typeable without a linkC release. `AgentModelCatalog`'s own id lists are seed suggestions only, never a validator: `linkc_switch_model` accepts any id configured in this mapping, not the catalog's hardcoded list.

## 6. Delegation

`linkc_delegate_task` gains one optional parameter:

- `tier`: `"light" | "standard" | "deep"`. Omitted, the task takes `defaultTier[toAgent]`.

The tier is resolved at creation, not at delivery, so the record says what it will run on.
`TaskRecord` gains `public let tier: ModelTier?`. It is optional for one reason: `loadUnlocked`
throws on a decode error, so a required field would make every task row written before this change
unreadable and take the inbox with it. `nil` means "created before tiers existed" and is handled by
the pre-tier rule in §7. Every task created from here on carries a tier.

`linkc_get_models` reports the configured mapping per agent and each agent's default tier, replacing its current listing of stale whitelist entries.

## 7. Sessions are pinned

`Session` gains `public var modelTier: ModelTier?` and `public var model: String?`, set when linkC launches the process and never changed afterward.

`spawnTeammate(in:agent:goal:)` gains a `tier:` argument. It resolves the model id from settings and appends `AgentModelCatalog.launchArguments(model:for:)` — `--model <id>`, which `claude`, `codex` and `agy` all accept — to the launch argv.

A tier only ever pins a brand-new process: `launch` refuses (`LinkCError.process`, no session or terminal created) rather than combine a `tier` with `.continueLast` or `.resume`. For Codex, that argv starts with the `resume` subcommand (`AgentDescriptor.continueArgs`/`resumeArgs`), so appending `--model <id>` after it — the way `.new` does — would land the flag after the subcommand instead of before it. No caller pairs a tier with anything but `.new` today, so refusing the combination outright costs nothing and avoids ever constructing that argv.

`dispatchTasks` adds one clause to its candidate filter: a session is a candidate only when
`session.modelTier == task.tier`. If no candidate exists, it spawns one pinned to that tier and
waits for readiness exactly as it does today; the frame goes in on a later tick once the agent is up.

A task whose `tier` is `nil` — a row written before this change — keeps today's behaviour exactly:
any idle session of the right kind, no tier clause, one log line saying so. These rows are gone
within the 4-hour lease, and no new ones are created.

`linkc_switch_model` stays, for switching a session by hand. The app re-derives `modelTier` on the
session record at the moment it performs the switch, in the same place that injects the command:
the new model is matched against that agent's mapping in tier order (`light`, then `standard`, then
`deep`, so two tiers sharing one id resolve to the lighter), and an unmapped model sets `modelTier`
to nil. A session with no tier receives no tiered work — the alternative is delivering a task to a
session running a model nobody asked for.

## 8. Reroute keeps the tier

`checkLimitsAndReroute` copies a rate-limited task to another agent kind. The copy keeps the task's `tier`, and the new agent resolves that tier through its own mapping. A `standard` task rerouted from Codex to Claude runs on `sonnet`, not on whatever Claude defaults to.

A candidate that cannot serve that tier — Cursor, always, or any agent with no model configured for it — is not a reroute target; picking one would strand the copy in `dispatchTasks` forever while the original had already been cancelled. When no candidate can serve the tier, the reroute does nothing: the original task is left exactly as it was, no reroute is announced to the delegator, and one line is logged saying why. This is distinct from every candidate being rate-limited or the hop limit being reached, which still trips the existing circuit breaker (session marked `.error`, delegator notified, swarm-rate-limited alert posted).

## 9. Failing loud

Three refusals, all returned as MCP errors naming exactly what is wrong:

- An unknown tier string: `tier must be light, standard or deep`.
- A tier with no model configured for that agent: `no model configured for codex tier light — set it in linkC settings`.
- A tiered task for Cursor, whose CLI takes no model flag: `cursor cannot be pinned to a model`.

No branch of this design falls back to "use the session that exists" or "use the agent's default model". A task that cannot be placed on its tier stays queued and visible rather than running expensively in silence.

## 10. Testing

- `AgentModelCatalogTests`: tier resolution from settings, a missing mapping, and a renamed model that is not in the seed list.
- `AppPreferencesTests`: the seeded defaults, a round trip through UserDefaults, an edited mapping
  surviving a reload, and two tiers mapped to one model id resolving to the lighter tier.
- `AppCoordinatorRelayTests`: a task reaches only a session of its tier; a spawn passes `--model <id>`
  for that tier; a session whose tier is nil is never a candidate for a tiered task; a legacy task
  with no tier still reaches any idle session of its kind; a reroute preserves the tier across agent kinds;
  a reroute never picks a candidate that cannot serve the tier and picks one that can; a tiered task with
  no capable peer is left in place rather than cancelled and stranded.
- `MCPServerTaskTests`: delegation accepts a tier, rejects an unknown one, applies the agent default when omitted, stamps the tier on the record, and returns each of the three refusals in §9.
- `MCPServerModelTests`: `linkc_switch_model` accepts any id `linkc_get_models` reports as configured (not the `AgentModelCatalog` seed list) and names the configured models on refusal; a settings edit made after the server is constructed is visible to the very next tool call, not frozen at construction.
- `AgentModelArgvLiveTests` (opt-in, `LINKC_LIVE_AGENT_TESTS=1`): the exact argv linkC builds for a pinned session is accepted by the real Codex CLI — the process starts and stays alive rather than exiting on an argument error.
- `AppCoordinatorIntegrationTests`: a tier combined with `.continueLast` or `.resume` is refused outright, with no session or terminal created.

## 11. Rollout

Ship with `./build-app.sh`, then restart linkC and its MCP clients as usual.

Sessions that were already running before the upgrade have no recorded tier, so they will not receive tiered tasks. linkC spawns a pinned session for the tier instead. Restarting a workspace's sessions after the upgrade avoids that extra session; nothing breaks if you don't.

## 12. Cost

A workspace that uses two tiers of one agent runs two sessions of that agent. That is the price of never mutating a session someone is mid-conversation with, and it is bounded by the number of tiers actually delegated to.
