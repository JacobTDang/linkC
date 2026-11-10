# Discord notifications

linkC posts its events to Discord channels through webhooks, so the user can follow the agent swarm from a phone. It only posts. Discord never sends anything back to linkC, and no Discord message ever reaches an agent.

## 1. Scope

- **In scope:** posting linkC's events to Discord webhooks, routed by project; a per-webhook queue that stays inside Discord's rate limits; a Settings section; webhook URLs in the Keychain.
- **Out of scope:** reading from Discord, a Discord bot, commanding agents from Discord, and per-event toggles.
- **A deliberate exception to "linkC never holds a credential".** A webhook URL is a secret: anyone who has it can post to the channel. The user approved keeping these URLs in the macOS Keychain, the only secret linkC stores. They never go in preferences, logs, notifications or error text.

## 2. Events

An event is a `LinkCEvent`:
- `kind`: one of the kinds below;
- `title` and `body`;
- `project`: the canonical project folder, or nil when the event belongs to no project;
- `at`: when it happened.

| Kind | Raised when | Project | Also a macOS notification |
|---|---|---|---|
| `sessionState` | an agent finished, needs permission, is waiting for input, or ended with an error (today's `post(session:)`, with its focus rule) | the session's folder | yes (today) |
| `alert` | every other alert linkC posts today: tasks look stuck, a turn ended with open tasks, rate limited, swarm rate limited, a notice can't land, a `linkc` prompt was not typed | the folder it concerns | yes (today) |
| `service` | a watched service went down or came back (`postAlert`) | none | yes (today) |
| `task` | a task became delivered, done, failed, expired or cancelled | the task's folder | **no** |
| `workerClosed` | linkC closed a worker: its task ended and it sat idle through the grace, or its delegator asked | the worker's folder | **no** |

- **The same focus rule.** A `sessionState` event goes to Discord exactly when its macOS notification is posted. While the user watches a session, neither fires.
- **Task events are Discord only.** Every task ending would make macOS notifications noisy.
- **Copy.** The title names the agent or task and the project. The body is the existing notification body, or, for a task, its short id, its agents (`Claude → Codex`), the first line of its prompt (up to 120 characters), and, when it ended, the report summary or the cancel reason.

### 2.1 Task events

Tasks change state in linkC and in every `linkc-mcp` process, so linkC finds the changes by comparing.
- **Each relay pass compares** a folder's task states with what the last pass saw (`TaskEventFeed`).
- **A task that moved to `delivered`, `done`, `failed`, `expired` or `cancelled`** raises one `task` event. Moves to `gating`, `queued`, `started` or `reported` raise none.
- **A task new since the last pass** raises the event for its current state, if that state is one of the five.
- **The first pass for a folder only records.** A folder seen for the first time, at linkC's start or when a session first opens there, raises no events, so a restart never posts the backlog.
- **A failed read** (lock timeout, I/O error) keeps the last snapshot, and the next pass compares again. Nothing is reported twice and nothing is lost.

## 3. Routing

- **A project's webhook.** An event whose project has its own webhook goes there.
- **The default webhook.** Every other event goes to the default webhook, including events with no project.
- **No webhook.** With no webhook for it, an event is not posted, and nothing else happens.
- **No fallback from a project's own webhook.** If a project's webhook is stopped (§4.4) or its Keychain item is missing (§6), the project's events are not posted at all. They never fall back to the default webhook, which could post one project's work into another project's server. Settings shows why.
- **Matching a project.** A project's webhook covers its folder only, matched on the canonical path, not subfolders.

## 4. The queue

Each webhook URL has its own `WebhookQueue`, a main-actor class. It sends one request at a time, in order.

### 4.1 Pacing

A request goes out only when all three hold:
1. **The sliding window:** fewer than **5** requests to this webhook in the last **2 seconds** (`window.limit = 5`, `window.length = 2 s`). The queue keeps the send times of its recent requests; once 5 fall inside the window, the next one waits until the oldest leaves it. Every request counts, answered or not.
2. **Discord's headers:** after a response with `X-RateLimit-Remaining: 0`, wait `X-RateLimit-Reset-After` seconds. Discord says its limits change and must be read, not hard-coded, so the window is the ceiling and the headers can only make it stricter.
3. **A 429:** after one, wait its `retry_after` seconds (body, else the `Retry-After` header), then resend the same message. A `"global": true` 429 pauses every webhook queue for that long, since the global limit is per IP.

### 4.2 Batching

- **When a request goes out**, the queue takes every waiting event, oldest first: it takes them after waiting for its turn (§4.1), so a burst that arrives during the wait goes in the same message.
- **One event** posts as one card (§5.1).
- **Several events** post as one digest card (§5.2), up to **15** events a page.
  - Pages are packed in order: an event joins the current page while it holds fewer than 15 and still fits Discord's limits (§5), else it starts the next. Each page's headline carries `(1/3)` and so on, and the pages go out in order, one request each, ahead of any event that arrives meanwhile.
  - Every page is built and checked against Discord's limits (§5) before the first is posted.
  - A page Discord refuses, or that runs out of retries, is dropped and counted (§4.3); the next page still goes.

### 4.3 Bound

- **At most 100 waiting events per webhook.** Past that, the oldest are dropped.
- **Dropped events are counted.** An event can be dropped here, or with a message Discord refused or never answered (§4.4). The next message carries one extra line: "⚠️ N earlier events were not posted." Settings says why.

### 4.4 Errors

| Response | What linkC does |
|---|---|
| 200 with a JSON body whose `id` is not empty | done; record "last posted at". Only this counts as sent (§5) |
| 204, an empty or non-JSON body, any other 2xx | not saved: retried like a 5xx below |
| 429 | wait (§4.1), resend the same message |
| 404, 401, 403 | the webhook is deleted or invalid: **stop**. Drop its queue, mark it stopped in Settings with the status code, and post one macOS notification. It stays stopped until its URL is set again or **Send test** is pressed, which starts it fresh. Discord asks clients not to reuse a 404 webhook, and repeated 401/403/429 responses get the IP banned. |
| 400, 413, any other 4xx | the message is malformed, which is a linkC bug, and retrying cannot fix it: log Discord's `code` and `message`, drop that message, show the error in Settings |
| 5xx, timeout, no network | retry the same message after 2, 4, 8, 16 and 32 s: the first attempt plus five retries. If the last retry fails too, drop it, log it, and show the error in Settings |

- **Logging never includes the webhook URL.** Logs name a webhook by "default" or by its project name. A transport error is reported by its type name (and a `URLError`'s code), never by its text, which can hold the URL.
- **No retry loop on a stopped webhook.** A stopped webhook makes no requests at all.

## 5. The message: the JD LLC house style

linkC posts in the JD LLC house style, the one every project on the user's Discord server uses (the user's `discord-webhook` skill, `references/house-style.md`). This section replaces the embed design of the first version of this spec. The user chose one digest card for a burst of events, and the Keychain for the URLs.

**Transport:**
- POST to the webhook URL with `with_components=true&wait=true` added as its query. Without `with_components`, Discord drops the components; without `wait`, a message Discord did not save still returns 204.
- The body is `{"flags": …, "components": [one container], "allowed_mentions": {"parse": []}}`.
  - It carries no `content`, `embeds` or `username`. The webhook's own name shows who posted, so Settings tells the user to name it "linkC".
  - `flags` always holds IS_COMPONENTS_V2 (`1 << 15`). It also holds SUPPRESS_NOTIFICATIONS (`1 << 12`) when every event in the message is information (§5.3): those post silently. Nothing else goes in `flags`.

**Limits, per message:**
- 40 components, nested ones included;
- 4000 text-display characters in total.

A page that would pass a limit is an error found before posting, never text cut silently. Event text is bounded where it is built, each cut visibly with `…`: a title to 100 characters, a detail line to 120, a folder name to 50. An event has at most 4 detail lines; a longer body shows its first 3 and then `… N more lines`. Characters are counted in UTF-16 units, as Discord does, and the paging above keeps every page under the limits.

**Text:**
- Text from agents, tasks and folders is markdown-escaped and kept on one line. Events carry plain text; only the message builder adds markdown.
- Times are Discord timestamps (`<t:UNIX:f>`, `<t:UNIX:R>`), so they show in the reader's time zone.
- Plurals are right: "1 event", "2 events".

### 5.1 One event

One Container (type 17), its `accent_color` set by the event's tone (§5.3), holding in order:
1. A text display: `## <emoji> <title>`.
2. The event's detail, as text-display lines (at most 4).
3. When events were dropped (§4.3): a line `⚠️ N earlier events were not posted.`
4. A separator (type 14).
5. A text display: `-# <project folder name> · <t:UNIX:f> (<t:UNIX:R>)`. With no project, it reads `-# <t:UNIX:f> (<t:UNIX:R>)`. The webhook's own name ("linkC") already says who posted, so the footer does not repeat it.

### 5.2 A digest

One Container, its colour that of the most serious event in it (failed, then needs you, then done, then information), holding:
1. `## 📋 N linkC events`, N counting the events on every page. A page of a split digest reads `## 📋 N linkC events (1/3)`.
2. For each event, in order:
   - one line: `<emoji> **<title>** · <project folder name>`;
   - under it, the first detail line as subtext: `-# <detail>`.
3. The dropped-events line, on the first page only, when there is one.
4. A separator.
5. `-# <t:UNIX:f> (<t:UNIX:R>)`, with the time of the newest event on the page.

### 5.3 Tones

| Tone | Events | Colour | Emoji | Notifies |
|---|---|---|---|---|
| done | an agent finished, a task done | green `0x57F287` | ✅ | yes |
| needs you | permission, waiting for input, stuck, rate limited, a notice that can't land | yellow `0xFEE75C` | ⚠️ | yes |
| failed | an agent's error, a task failed or expired, a watched service down | red `0xED4245` | ❌ | yes |
| information | a task delivered or cancelled, a worker closed, a service back up | blurple `0x5865F2` | 📋 | no (SUPPRESS_NOTIFICATIONS) |

**Deliberate difference from the house style:** a 429's wait is clamped at an hour, not 60 seconds. linkC runs for days, so it can afford the real wait. Retrying before Discord's own `retry_after` would only earn more 429s, which Discord counts toward its ban.

### 5.4 Live check

One test posts a card of each tone and one digest to the user's `#bot-preview` channel through the real transport. It runs only when `DISCORD_PREVIEW_WEBHOOK_URL` is set, from `~/.config/jd-llc/discord-preview-webhook`, and is skipped otherwise. It asserts that each post was saved (Discord returned an id). Then someone looks at the channel before the work is called done: Discord accepting a message says nothing about how it reads.

## 6. Settings and the Keychain

- **A DISCORD section** in the Settings screen, after WATCHED SERVICES:
  - **Default webhook:** its state ("Not set", or "Webhook <id>" and its status), with **set**/**change** (a secure field, cleared once stored), **test** and **remove**.
  - **Per project:** a list of project folders, each with its webhook, **Send test** and **Remove**, and **Add project** (a folder picker).
  - **Status per webhook:** "Not posted yet", "Posted 2m ago", "Waiting 4s for Discord", "Stopped: webhook deleted (404)", or "Failed: <the last error>".
- **URL check.** A URL is accepted only if it is `https://` on `discord.com`, `discordapp.com`, `canary.discord.com` or `ptb.discord.com`, with the path `/api/webhooks/<numeric id>/<token>`. Anything else is refused in the field, with the reason.
- **Send test** posts one card, "linkC is connected", through the same queue. Its outcome shows in the status.
- **Storage:**
  - Each URL is a Keychain generic password, service `com.linkc.app.discord-webhook`, account `default` or the canonical project folder.
  - The list of projects that have one is kept in `AppPreferences`; that list holds no URLs.
- **A missing secret.** A project in the list whose Keychain item is missing shows "Webhook missing — set it again", and its events are not posted until it is set (§3).

## 7. Components

| Unit | Does | Depends on |
|---|---|---|
| `LinkCEvent` | the event value | — |
| `DiscordRouter` | event → webhook URL (§3) | `DiscordWebhookConfig` |
| `DiscordWebhookConfig` | which projects have webhooks, URL validation, reading and writing URLs | `SecretStore`, `AppPreferences` |
| `SecretStore` | protocol: get, set, delete a secret by service and account. `KeychainSecretStore` (SecItem) in the app, an in-memory one in tests | — |
| `DiscordMessage` | events → the JSON body, with the batching limits and cuts (§4.2, §5); pure | — |
| `WebhookQueue` | one webhook's pacing, batching, bound, retries and errors (§4) | `WebhookTransport`, a `Clock`, the shared global pause |
| `WebhookTransport` | protocol: POST a body, get status, headers and body. `URLSessionWebhookTransport` (ephemeral session, 10 s timeout, no redirects) in the app | — |
| `DiscordNotifier` | owns the queues and the global pause they share (§4.1, a global 429), keeps their status for Settings, receives events | the above |
| `TaskEventFeed` | per-folder task snapshots → `task` events (§2.1) | — |

**Wiring:**
- `NotificationManager` gains an optional `onEvent: (LinkCEvent) -> Void`. `post(session:)`, `post(title:body:project:)` and `postAlert` call it whenever they deliver. Every existing `post(title:body:)` call passes the folder it concerns.
- The relay's pass feeds `TaskEventFeed` and sends its events to `DiscordNotifier` directly. The worker-closing paths in `AppCoordinator+Workers.swift` send `workerClosed`.
- The app creates `DiscordNotifier` with the Keychain store and `URLSessionWebhookTransport`. Tests create it with fakes.

## 8. Testing

Every test goes through the seams: a scripted `WebhookTransport`, a manual clock, and an in-memory `SecretStore`. None touches the network or the Keychain.

**`WebhookQueue`:**
- 5 sends inside 2 s go out at once, the 6th waits until the first leaves the window, and a 6th 2 s later goes at once;
- `Remaining: 0` with `Reset-After: 1.5` holds the next send 1.5 s;
- a 429 with `retry_after: 0.7` resends the same body after 0.7 s;
- a global 429 pauses another webhook's queue too;
- 30 events become 2 digest pages of 15, `(1/2)` and `(2/2)`, and a later event waits behind both;
- long events split pages at Discord's limits, and every page stays under them;
- a 204, or a 200 without an `id`, is retried; every request asks for `with_components=true&wait=true`;
- 101 waiting events drop the oldest, and the next message counts it;
- a 404 stops the webhook, makes no further requests, and posts one macOS notification;
- a 500 is retried on 2, 4, 8, 16, 32 s, then dropped and reported;
- a 400 is dropped and reported at once.

**The rest:**
- **`DiscordMessage`:** one container and only `flags`, `components` and `allowed_mentions` (empty); each tone's color, emoji and silence; escaping and the visible cuts; the card and digest layouts line by line; a message over a limit is an error.
- **Live:** the preview test of §5.4.
- **`DiscordRouter`:** a project's webhook, the default for other projects and for events with no project, no fallback for a stopped or missing project webhook, and a subfolder not matching.
- **`DiscordWebhookConfig`:** each accepted host and the rejected shapes (http, another host, a non-numeric id, extra path).
- **`TaskEventFeed`:**
  - the first pass is silent;
  - each of the five states raises one event, and the other four raise none;
  - a new task already done raises done;
  - a failed read neither loses nor repeats an event.
- **Wiring:** an existing alert raises an event with its folder; a session alert suppressed by the focus rule raises none.

## 9. Manual checks

1. Set a default webhook and press **Send test**: "linkC is connected" appears in the channel.
2. Delegate a task: delivered and done appear, with the project in the footer.
3. Give one project its own webhook: its events move there, and the others stay on the default.
4. Delete the webhook in Discord: the next event marks it stopped in Settings, and one macOS notification says so.
5. Have several workers finish at once: the posts arrive grouped, and none is missing.
