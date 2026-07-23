# Container Depth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. TDD per pure piece.

**Goal:** Ship the four approved container-depth features on the existing Tool Servers seams.

## Task order

1. **Parsers (TDD, fixtures = real captured output)** — `Sources/LinkCKit/Config/DockerDetail.swift`:
   `DockerInspect.parse` (image, status, startedAt, restartCount, ports flattened, mounts
   `type dest` strings, env KEY NAMES only — values discarded at parse); `DockerStats.parse`
   ("CPUPerc"/"MemUsage" strings passed through); `DockerImages.parse` (newline JSON;
   repo:tag, size, dangling = `<none>` repo, id). Tests in `ToolServerTests.swift`.
2. **KnownStacksStore (TDD)** — `Sources/LinkCKit/Config/KnownStacksStore.swift`: JSON file
   in injected directory (WorkspaceManifest pattern): `remember(name:workingDir:)` upsert,
   `stacks`, `forget(name:)`, load-tolerates-missing/corrupt. Tests with temp dirs.
3. **Service (TDD, FakeRunner)** — extend `ToolServerService`: `coldProjects` (known minus
   live), remember-on-refresh; `projectUp/projectDown` (compose args + `--project-directory`,
   120s), `pullImage(ref:)`, `pruneImages()` (`image prune -f`); `images` on refresh
   (`docker images --format json`); `loadDetail(id:) async -> ContainerDetail?` composing
   inspect + stats + `logs --tail 40` (each degrading independently — a stats failure
   doesn't kill the overview). CLI-argument contract tests + failure surfacing.
4. **UI** — `ToolServersScreen`: cold-stack dim cards w/ Up; project header gains Down;
   container rows + detail gain exec (`docker exec -it <name> /bin/sh` via
   `model.openContainerExec`, command-mode dev terminal); `ContainerDetailView` drill-in
   (local back, overview grid, stats line, static log tail, follow/exec buttons); IMAGES
   section w/ Pull per row + Prune dangling behind an NSAlert-style confirm. AppModel:
   `openContainerExec(_:)`.
5. **Verify** — full suite + TSan; `./build-app.sh --install` + relaunch (live-session
   check); manual: firecrawl down→cold card→Up from cold; detail on api container (env keys
   only — no values anywhere); exec into proxy; prune with only dangling images affected.
