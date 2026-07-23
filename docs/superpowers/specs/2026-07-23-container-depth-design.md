# Container depth: cold stacks, detail drill-in, exec, images

## Problem

Tool Servers v1 only sees what `docker ps` reports: a downed stack vanishes entirely, a
container is an opaque row, and image housekeeping needs a terminal.

## Design (user-approved)

1. **Cold stacks** — a persisted `KnownStacksStore` (Application Support JSON) auto-remembers
   every compose project the screen sees (name, working dir). Downed stacks stay listed as
   dim cards with **Up** (`docker compose -p <name> --project-directory <dir> up -d`, 120s
   timeout); running stacks gain **Down** (removes containers — copy distinguishes it from
   stop, which keeps them).
2. **Detail drill-in** — clicking a container pushes a detail view (skill-reader local-back
   pattern): overview from `docker inspect` (image, state, started-at, restart count, ports,
   mounts, env **key names only** — values are discarded at parse time, same structural
   redaction as MCP headers), a one-shot CPU/mem line from `docker stats --no-stream`, and a
   static `docker logs --tail 40` block, with follow-in-terminal and exec actions.
3. **Exec** — `docker exec -it <name> /bin/sh` in a command-mode dev terminal (sh, always
   present; bash-from-sh when the image has it). Action on detail view + container rows.
4. **Images & housekeeping** — section listing `docker images --format json` (repo:tag,
   size, dangling = `<none>` repo), per-image **Pull**, and **Prune dangling images** behind
   a confirmation dialog. **Volume prune is excluded** — the firecrawl database lives in a
   volume; deleting data is not light management. Image prune only reclaims rebuildables.

## Architecture

Existing seams throughout: three new pure parsers (`DockerInspect`, `DockerStats`,
`DockerImages`) TDD'd against output captured from this machine; `ToolServerService` grows
the actions (up/down/pull/prune), detail loading, and the known-stacks merge (known project
with no live containers → cold card); the screen gains the drill-in, cold-card state, and
images section. Docker CLI only; every action re-reads state; errors loud.

## Out of scope

Volume prune, container create/run, registry auth for private pulls, streaming stats,
compose file editing.
