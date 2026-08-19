# CLOUD section — Oracle first

## Goal

Cloud compute status at a glance: a CLOUD section in the sidebar listing the user's
Oracle compute instances (name, state, shape/region), so "is my box up and mine?" stops
requiring a console login. Supabase and others follow the same pattern later.

## Principles

- linkC never holds cloud credentials: it shells out to the `oci` CLI, which owns auth
  via `~/.oci/config` — the same trust model as `docker` and `claude`.
- Cloud cadence ≠ local cadence: calls take 1–3s and are rate-limited. Refresh on panel
  open plus every 120s while the panel stays visible (usage timer, every 24th tick).
  Never the 15s docker loop.
- Absent quietly: no `oci` binary, no config, or no instances → no section. The sidebar
  never states an absence.

## Data

`Sources/LinkCKit/Config/OracleService.swift` (+ pure parsers beside it):

- `OCIConfig.tenancy(from:)` — the DEFAULT profile's `tenancy` OCID out of the ini-style
  `~/.oci/config` (first `tenancy=` line wins; nil when missing).
- `OracleInstances.parse(_:) -> [OracleInstance]` — from `oci compute instance list
  --compartment-id <tenancy> --output json`: `display-name`, `lifecycle-state`, `shape`,
  `region`, `id`. Terminated instances are dropped (console noise, not state).
- `OracleService` (`@MainActor @Observable`, mirrors `ToolServerService`): `ociPath`
  detection (`/opt/homebrew/bin/oci`, `/usr/local/bin/oci`), `instances`, `isRefreshing`
  guard, `lastError` kept quiet (stale rows beat a vanishing section on a network blip;
  the row set only empties when a successful call says so). Env for the child process
  carries `SUPPRESS_LABEL_WARNING=True` (the CLI's key-hygiene banner is stdout noise).

## UI

Sidebar (compact mode) section `CLOUD` below SERVERS: one row per instance — quiet dot
(RUNNING → textSecondary, anything else → textTertiary), instance name, region tertiary
trailing. Tapping opens the Oracle console's instances page in the browser (linkC has no
cloud screen yet; the console is the drill-in).

## Testing

TDD in LinkCKitTests: config parse (tenancy present / missing / commented), instance
parse (running + stopped + terminated-dropped, real CLI field names), service contract
over `FakeRunner` (CLI invocation shape, missing-binary no-op).

## Out of scope (v2+)

Audit-event surfacing, CPU metrics, security-list summaries (today's one-off checkup is
the manual version); Supabase (CLI not installed yet); any write actions; push/webhook
event feeds.
