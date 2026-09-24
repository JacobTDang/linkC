# The Board's diagram engine: layout, routing, labels and component visuals

Jacob, looking at linkC's own map after an agent drew it with `linkc_edit_board`: "this right here is
just unreadable". Then: "I would like components to have labels and designs for UI, like database has
the cylinder thing, redis has the logo, docker has logo… better visuals as well."

Three things made the map unreadable:
- **Labels.** Every arrow label was drawn full size at the arrow's midpoint, so labels piled on each
  other and on boxes.
- **Layout.** Agent additions went into one tall column per frame, with frames packed side by side,
  so arrows had no room.
- **Routing.** Arrows ran through frames and bunched along the top edge.

Decisions Jacob made:
- the **full diagram engine**, not a lighter fix;
- the board **re-arranges after every agent edit**;
- components use **style A**: a shape per kind, with brand logos;
- the resting and hover mockups (in `.superpowers/brainstorm/…/board-layout-v6.html`) "look a lot
  better".

## 1 · Components

### The `tech` field

A component gains an optional `tech`, a short technology id such as `"postgres"`, `"redis"` or
`"docker"`.
- **In the file:** written as `"tech"` inside the component, in `places`. It round-trips like every
  other field. `BoardMerge` merges it with `pick`. `BoardReport` shows it.
- **For agents:** `linkc_edit_board` takes `"tech"` on `add` and `update` (`""` clears it), and
  `linkc_get_board` shows it. The tool description lists the known ids.
- **Inference:** a component with no `tech`, whose name exactly matches a known id or an agent name
  (case-insensitive), is drawn with that logo. Inference never writes `tech` into the file.
- **Unknown values:** a `tech` that isn't a known id is kept verbatim and drawn with the kind's icon.

**Known ids.** Logos come from Simple Icons (CC0). The id is Simple Icons' slug, with friendly
aliases:

| id | aliases | display name |
|---|---|---|
| `postgresql` | postgres, pg | PostgreSQL |
| `mysql` | | MySQL |
| `mariadb` | | MariaDB |
| `sqlite` | | SQLite |
| `mongodb` | mongo | MongoDB |
| `redis` | | Redis |
| `rabbitmq` | | RabbitMQ |
| `apachekafka` | kafka | Kafka |
| `docker` | | Docker |
| `kubernetes` | k8s | Kubernetes |
| `nginx` | | nginx |
| `nodedotjs` | node, nodejs | Node.js |
| `python` | | Python |
| `go` | golang | Go |
| `rust` | | Rust |
| `swift` | | Swift |
| `deno` | | Deno |
| `bun` | | Bun |
| `supabase` | | Supabase |
| `firebase` | | Firebase |
| `vercel` | | Vercel |
| `cloudflare` | | Cloudflare |
| `stripe` | | Stripe |
| `github` | | GitHub |
| `googlecloud` | gcp | Google Cloud |
| `digitalocean` | | DigitalOcean |
| `elasticsearch` | | Elasticsearch |
| `graphql` | | GraphQL |
| `prisma` | | Prisma |
| `nextdotjs` | next, nextjs | Next.js |
| `react` | | React |
| `fastapi` | | FastAPI |
| `django` | | Django |
| `rubyonrails` | rails | Rails |
| `spring` | | Spring |
| `minio` | | MinIO |
| `clickhouse` | | ClickHouse |
| `neo4j` | | Neo4j |
| `sentry` | | Sentry |
| `grafana` | | Grafana |
| `prometheus` | | Prometheus |
| `auth0` | | Auth0 |
| `resend` | | Resend |
| `netlify` | | Netlify |
| `flydotio` | fly | Fly.io |
| `railway` | | Railway |
| `render` | | Render |

The agents `claude`, `codex`, `cursor` and `antigravity` (alias `agy`) reuse `AgentKind`'s existing
logos.

Brands whose colour is black or near-black are drawn in the panel's primary text colour. AWS, Oracle,
Azure and OpenAI withdrew their marks from Simple Icons, so they have no logo: those components get
the kind's icon.

### The shape per kind (style A)

Every shape fits the same 176 × 84 pt box, so the layout stays a grid:

| Kind | Shape |
|---|---|
| database | A cylinder: an elliptical top over a body with a rounded bottom. |
| cache | A cylinder with a dashed second rim. |
| queue | A pipe: a capsule with three chevrons at its right end. |
| storage | A bucket: a trapezoid, wider at the top. |
| host | A server: a card with three rack lines on its right. |
| external | A cloud, with a dashed outline, since it lives outside the system. |
| service, and any unknown kind | A card. |

Inside each shape:
- the logo, or the kind's icon;
- the name;
- a sub-line: `KIND · <tech display name>`. With no tech it is `KIND · <reached_by>`, truncated, and
  with neither it is just `KIND`.

The selection, status (running or not found) and "planned" treatments stay as today, drawn along the
shape's outline.

## 2 · The engine

It has three pure parts in LinkCKit, each deterministic and each tested. The Board and the MCP tool
share them.

### Layout: `BoardLayout.arranged(_ map: BoardMap) -> BoardMap`

**Clusters.**
- Each frame is a cluster, and so is the set of Not-placed components.
- Clusters are ranked left to right by the direction of the arrows between them. Cycles are broken
  by a stable depth-first order.
- Clusters of the same rank stack vertically, ordered by the mean row of the components they
  connect to.

**Inside a cluster.**
- Components go into columns by longest path along the cluster's own arrows.
- Within a column, rows are ordered by the average row of their neighbours (a barycentric pass, run
  a fixed number of times).
- Ties break by name.

**Grid.**
- Cells are 176 × 84.
- The gap between columns is 136 inside a frame and 184 between frames.
- The row step is 132.
- Frames have 24 pt padding and a 34 pt title band.
- Frames at the same rank are separated by at least one empty row.

**Everything else.**
- Notes stack in a column to the right of the diagram, 48 pt clear, in their file order.
- Texts keep their position. A text that now overlaps something moves to the nearest free spot, by
  the existing rule.

**When it runs.**
- After every successful `linkc_edit_board`, before the save.
- From a new **Tidy up** button in the Board's toolbar: one edit, one undo step.

The Board's own edits never re-arrange: a drag, adding a component, "Add what's running". The user's
arrangement stays until the next agent edit or Tidy up.

### Routing: `BoardRouter.routes(for map: BoardMap) -> [ArrowKey: BoardRoute]`

This replaces `BoardGeometry.route`. It works on any positions: arranged boards and hand-dragged ones.

**Obstacles.**
- Every component box, inflated by 12 pt.
- For an arrow, every frame that contains neither of its ends, inflated by 12 pt.
- An arrow may cross the border of its own ends' frames.

**The path.**
- Arrows are orthogonal.
- A path is found on the sparse grid of obstacle-edge and gutter coordinates, by A*. Its cost is
  length plus a penalty per bend, plus a penalty for running alongside an existing route.
- It leaves the source on the side facing the target and enters the target the same way.
- A backward arrow (target to the left) leaves by the side that gives the shortest valid path.

**Separation.** Arrows sharing a corridor get separate lanes 8 pt apart. A final pass nudges
segments in the same channel apart.

**Bundles.**
- Arrows with the same source and the same label share the source port and their first segment.
- Arrows with the same target and the same label share the target port and their last segment.
- An unlabelled arrow never bundles.

**Straight lines.** Neighbours whose facing sides overlap vertically, or horizontally, connect with
one straight segment.

**Result.** A route carries its points, rounded 7 pt at each bend when drawn, and its bundle id.

**Performance.**
- Routes are computed only when the map changes, never per frame.
- While a box is dragged, the live preview draws its own arrows as straight dashed lines. On
  release, the full routes are recomputed.
- Routing runs off the main actor; the latest change wins, and a stale result is dropped.
- **Budget:** 200 components with 300 arrows route within 150 ms on this Mac. A timed test pins it.

### Labels: `BoardLabels.placed(routes:boxes:frames:) -> [ArrowKey: BoardRect]`

- A label is a pill: 10 pt text, 7 pt horizontal padding, 18 pt tall.
- For each labelled route, in a stable order (bundles first, then by length), the candidates are:
  1. its horizontal segments, longest first, sliding from the centre outwards in 10 pt steps;
  2. then its vertical segments, the pill centred on the line.
- A position is taken only if the pill overlaps no box, no frame title and no placed label.
- A bundle places its label once, on its shared segment.
- A label that finds no room is not drawn at rest. It shows on hover.

## 3 · Drawing and interaction

- **Arrows** are drawn in the canvas's single pass, as now, with the rounded corners and arrowheads
  of the mockup. **Labels** are drawn in the same pass, as pills.
- **Hovering or selecting a component:**
  - its arrows and their labels turn the accent colour, including labels hidden for lack of room;
  - every other arrow drops to 12% opacity;
  - unrelated components drop to 30%.
- **Hovering an arrow** shows its label, if hidden, and highlights it.
- **Tidy up** sits in the toolbar next to the existing tools and is disabled while the Board is
  locked.
- **Power:**
  - layout, routes and labels are cached and recomputed only on a map change;
  - hover changes opacity only;
  - nothing animates or recomputes while idle.

## 4 · Testing (LinkCKit, TDD)

- **`BoardLayoutTests`:**
  - determinism: the same map gives the same layout;
  - flow order across frames, and inside a frame;
  - frames at the same rank stacked without overlap;
  - no two boxes overlap;
  - every component wholly inside its own frame;
  - notes to the right;
  - a cycle doesn't hang;
  - Not-placed components as their own cluster;
  - the linkC map from this session laid out without overlap.
- **`BoardRouterTests`:**
  - no route crosses any component box;
  - no route crosses a foreign frame;
  - same-row neighbours get one segment;
  - lanes are separated in a shared corridor;
  - bundles share a port and a first segment;
  - a backward arrow is routed;
  - a hand-dragged, off-grid board still routes without crossings;
  - the 200/300 timing budget.
- **`BoardLabelsTests`:**
  - no label overlaps a box, a frame title or another label;
  - a bundle labelled once;
  - no room means not placed;
  - deterministic.
- **`BoardEditTests` / `BoardMapTests` / `BoardMergeTests` / `MCPServerBoardTests`:**
  - `tech` decode, encode and round-trip;
  - `tech` on `add`/`update` and clearing it;
  - an unknown tech kept verbatim;
  - `tech` merged;
  - an MCP edit returns an arranged map (positions follow `BoardLayout`).
- **`BoardTechTests`:**
  - alias resolution;
  - name inference;
  - every known id's embedded SVG loads (`NSImage`, SVG representation, 24 × 24);
  - black brands flagged for tinting.

These are checked by hand in the app:
- the shapes and logos at 12–100% zoom;
- hover dimming;
- Tidy up and its undo;
- redrawing linkC's own map after the build.

## Out of scope

- Arrows to or from a frame, as opposed to a component.
- Custom colours per component.
- Manual routing: dragging an arrow's path.
- Remembering the user's arrangement across an agent edit. Jacob chose re-arranging every time.
