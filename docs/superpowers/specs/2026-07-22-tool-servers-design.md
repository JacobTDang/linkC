# Tool Servers screen

## Problem

The user's tools depend on long-running local services — today a customized firecrawl compose
stack (proxy, api, SearXNG, playwright, redis, rabbitmq) — with no visibility from linkC. The
MCP screen shows protocol-level "connected"; the layer below (is the backing stack actually
up?) is invisible.

## Design

The unit is the **service, not the container**: a fifth rail tile "Tool Servers" opens a
screen of compose-project cards (project name, config dir, aggregate state) with one child
row per container (compose service name, state/health chip, published ports), plus a
STANDALONE section for non-compose containers. Data from `docker ps --all --format json`
(newline-delimited JSON; compose project/service parsed from the `Labels` field) through the
existing timeout-enforced `ProcessRunner`.

Light management, all via the docker CLI: per-container start/stop/restart; per-project
stop/restart (`docker compose -p <name> …`); **View logs** opens a dev terminal running
`docker logs -f` — which requires `ShellCoordinator` to gain a run-a-command variant
(`launch(cwd:command:title:)`, shell `-l -c` so PATH/dotfiles load; when the command exits
the terminal shows the normal exited card).

Docker binary resolved by probing (`/usr/local/bin/docker`, `/opt/homebrew/bin/docker`,
`~/.docker/bin/docker`) — Finder-launched apps have minimal PATH; missing docker or a
stopped daemon fails loud as screen-level guidance, never a crash. Five rail tiles trigger
the deferred mitigation: the rail becomes scrollable.

## Out of scope (v1)

Non-docker tool servers (saved command + port check — queued with dev-terminal saved
commands), `docker compose up` for fully-removed stacks, container inspect/stats, MCP-screen
cross-links.

## Testing

TDD for everything pure: ps-line parsing (real captured fixture), compose-label extraction,
project grouping, docker path resolution, service composition + CLI-argument contracts via
the existing FakeRunner, ShellCoordinator command-mode launch. UI verified by build + panel.
