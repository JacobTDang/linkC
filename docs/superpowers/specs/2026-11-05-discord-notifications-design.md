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

Each webhook URL has its own `WebhookQueue`, an actor. It sends one request at a time, in order.

### 4.1 Pacing

A request goes out only when all three hold:
1. **The sliding window:** fewer than **5** requests to this webhook in the last **2 seconds** (`window.limit = 5`, `window.length = 2 s`). The queue keeps the send times of its recent requests; once 5 fall inside the window, the next one waits until the oldest leaves it. Every request counts, answered or not.
2. **Discord's headers:** after a response with `X-RateLimit-Remaining: 0`, wait `X-RateLimit-Reset-After` seconds. Discord says its limits change and must be read, not hard-coded, so the window is the ceiling and the headers can only make it stricter.
3. **A 429:** after one, wait its `retry_after` seconds (body, else the `Retry-After` header), then resend the same message. A `"global": true` 429 pauses every webhook queue for that long, since the global limit is per IP.

### 4.2 Batching

- **When a request goes out**, the queue packs every waiting event into it, oldest first, up to Discord's limits: **10 embeds** and **6000 characters** across them. A burst of 30 events is 3 requests.
- **Long fields are cut** to fit Discord's limits, with an ellipsis: title 256 characters, description 4096, footer 2048.

### 4.3 Bound

- **At most 100 waiting events per webhook.** Past that, the oldest are dropped.
- **Dropped events are counted.** The next message carries one extra line: "N earlier events were not posted (Discord was rate limiting)."

### 4.4 Errors

| Response | What linkC does |
|---|---|
| 2xx | done; record "last posted at" |
| 429 | wait (§4.1), resend the same message |
| 404, 401, 403 | the webhook is deleted or invalid: **stop**. Drop its queue, mark it stopped in Settings with the status code, and post one macOS notification. It stays stopped until its URL is edited or **Send test** succeeds. Discord asks clients not to reuse a 404 webhook, and repeated 401/403/429 responses get the IP banned. |
| 400 | the message is malformed, which is a linkC bug: log the response body, drop that message, show the error in Settings |
| 5xx, timeout, no network | retry the same message after 2, 4, 8, 16 and 32 s: the first attempt plus five retries. If the last retry fails too, drop it, log it, and show the error in Settings |

- **Logging never includes the webhook URL.** Logs name a webhook by "default" or by its project name.
- **No retry loop on a stopped webhook.** A stopped webhook makes no requests at all.

## 5. The message

One POST to the webhook URL with JSON:
- `username: "linkC"`;
- `allowed_mentions: { "parse": [] }`, so no text from a task or an agent can ping anyone;
- `embeds`: one per event, each with:
  - `title`;
  - `description` (the body);
  - `color`: green `0x3BA55C` for done, amber `0xFAA61A` for needs-you (permission, waiting, stuck, rate limited), red `0xED4245` for failed, errored, expired or stopped, grey `0x99AAB5` for the rest;
  - `footer.text`: the project folder's name, or "linkC";
  - `timestamp`: the event's `at`, ISO 8601.

## 6. Settings and the Keychain

- **A DISCORD section** in the Settings screen, after WATCHED SERVICES:
  - **Default webhook:** a secure field showing only whether one is set (`••••` and the webhook's id), with **Set**, **Send test** and **Remove**.
  - **Per project:** a list of project folders, each with its webhook, **Send test** and **Remove**, and **Add project** (a folder picker).
  - **Status per webhook:** "Posted 2m ago", "Waiting: rate limited for 4s", "Stopped: webhook deleted (404)", or the last error.
- **URL check.** A URL is accepted only if it is `https://` on `discord.com`, `discordapp.com`, `canary.discord.com` or `ptb.discord.com`, with the path `/api/webhooks/<numeric id>/<token>`. Anything else is refused in the field, with the reason.
- **Send test** posts one embed, "linkC is connected", through the same queue. Its outcome shows in the status.
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
- 30 events become 3 requests of 10 embeds;
- the 6000-character limit splits a batch;
- 101 waiting events drop the oldest, and the next message counts it;
- a 404 stops the webhook, makes no further requests, and posts one macOS notification;
- a 500 is retried on 2, 4, 8, 16, 32 s, then dropped and reported;
- a 400 is dropped and reported at once.

**The rest:**
- **`DiscordMessage`:** `allowed_mentions` is empty; the colors per kind; the field cuts; an `@everyone` in a body does not ping.
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
