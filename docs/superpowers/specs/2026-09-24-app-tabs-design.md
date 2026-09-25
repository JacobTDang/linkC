# App tabs: host local web apps in project tabs

Jacob, 2026-09-24: "If I make other macOS apps, should there be a proper wrapper that I should use to be able to open it in a tab in linkC … a certain way I should develop the app that is optimized for linkC." He also said: "I definitely don't want to keep these persistent, since it's expensive to keep running throughout session restarts."

The first app is Circuit MCP (`~/Projects/circuit_mcp`). Its own `Circuit MCP.app` already does what linkC will do:
- start a Python server on a free local port;
- wait for a health check to pass;
- show the web desk in a `WKWebView`;
- stop the server on quit.

linkC generalizes that pattern into project tabs.

Decisions:
- apps come from a file in the repo and from Settings ("Both");
- an app runs until its tab closes ("Keep it until the tab closes").

## 1 · The linkC app contract

**Why web.** macOS can't embed another app's window inside a view. ExtensionKit remote views need app extensions, extension points and real signing. Mirroring a window with ScreenCaptureKit costs power and needs Screen Recording permission. So a linkC app serves its UI as a local web page, and linkC is the wrapper. An app with a SwiftUI-only UI opens in its own window instead, and that is out of scope here.

**The manifest.** An app describes itself in `.linkc/app.json` at its repo root:

```json
{
  "name": "Circuit MCP",
  "start": ["uv", "run", "python", "run_ui.py", "--port", "{port}"],
  "health": "/healthz",
  "path": "/",
  "env": { "KEY": "value" }
}
```

- **`name`** (required, non-empty): the tab title and the menu item.
- **`start`** (required, a non-empty array of strings): the argv, run with the repo root as its working folder.
  - `start[0]` is resolved on the user's login-shell PATH, as linkC already resolves agent CLIs.
  - Every `{port}` in any argument becomes the chosen port. linkC also sets `LINKC_PORT=<port>`.
- **`health`** (required, starts with `/`): an HTTP GET to `http://127.0.0.1:<port><health>` must return a 2xx once the app is ready.
- **`path`** (optional, starts with `/`, default `/`): the page linkC opens. linkC adds the query `linkc=1` to it.
- **`env`** (optional, string to string): extra environment variables.

An unknown key is ignored. A missing or invalid required field is an error that names the field.

**What the server must do:**
- bind to `127.0.0.1` only, on the port linkC gives it;
- pass the health check within 60 s of starting;
- exit on SIGTERM within 5 s. linkC then sends SIGKILL to the whole process group, so a child process must not leave that group;
- write logs to stdout and stderr. linkC keeps the last 200 lines;
- keep its state on disk, because the app stops each time its tab closes.

**Optional:** use a dark background, and hide the app's own title or header when the URL has `linkc=1`.

## 2 · Where apps come from

- **Project apps.** When a project folder contains `.linkc/app.json`, that app is available in the project. linkC reads the file each time it builds the menu, so an edit takes effect at once.
- **Settings apps.** **Settings > Apps** lists apps that the user registers by hand. Each one has a folder and the same fields as the manifest: name, start, health, path. These apps are available in every project. linkC stores them with its other preferences.
- **The same app twice.** If a Settings app and a project app share a folder, the project app is the one shown.

## 3 · Lifecycle and power

- Nothing starts when linkC launches.
- **Open.** Picking an app opens a tab in the project's tab strip (after the Board, the sessions and the terminals, in the order opened) and starts the app. At most one tab exists for each app in a project; picking it again selects that tab.
- **Starting.** linkC chooses a free local port and spawns the process in a new process group, with its stdout and stderr captured. It polls the health URL every 250 ms. The tab shows "Starting…".
- **Running.** On the first 2xx, the tab shows the page in a `WKWebView`. The app keeps running while the tab is open, even when the tab is hidden or the panel is closed. WebKit throttles hidden pages on its own.
- **Failed.** The process exits before it is healthy, or 60 s pass, or the start command can't be resolved. The tab shows the reason and the last log lines, with **Retry**.
- **Exited.** If the process exits while running, the tab shows "The app stopped" with its exit status and log lines, and **Start**.
- **Stop.** Closing the tab or quitting linkC sends SIGTERM to the process group, then SIGKILL to the group after 5 s. Closing the tab removes it from the strip.
- **Relaunch.** linkC remembers which app tabs were open in each project. After a restart they come back **asleep**, showing the app name and a **Start** button. linkC never starts them itself.

## 4 · Pieces

- **LinkCKit, pure and tested:**
  - `LinkCAppManifest`: decodes and validates a manifest, with errors that name the field;
  - `LinkCAppManifest.launch(port:)`: builds the argv (with `{port}` replaced), the environment additions and the page URL.
- **LinkCKit, lifecycle, tested with a real child process:** `LinkCAppProcess` has these states: `asleep`, `starting`, `running(url)`, `failed(reason)` and `exited(status)`, with the log kept live beside the state. It covers:
  - the free port;
  - the spawn in its own process group;
  - the health poll with a timeout;
  - the log ring buffer;
  - stopping (SIGTERM, then SIGKILL to the group).
  The clock, the poll interval and the timeouts can be injected.
- **LinkCKit, the model:**
  - `ProjectTabs` gains an app tab kind;
  - the open app tabs of each project are saved with the sidebar state and restored as asleep;
  - Settings apps are stored in `AppPreferences`.
- **App target:**
  - an `AppTabView` that shows the four states, and a `WKWebView` when running;
  - an **Apps** section in the project **+** menus;
  - a **Settings > Apps** editor;
  - stopping every app on quit.

## 5 · Testing (test-first, LinkCKit)

- **Manifest:**
  - a valid file decodes;
  - each missing or invalid required field gives an error that names it;
  - unknown keys are ignored;
  - `{port}` is replaced in every argument, and `LINKC_PORT` is set;
  - the page URL carries `linkc=1`.
- **Process:** a real `/usr/bin/python3 -m http.server`, or a small shell script that serves the health path, shows:
  - starting → running;
  - a start command that exits at once gives failed, with its log;
  - a health check that never answers fails after an injected short timeout;
  - stop ends the whole process group, including a child the script started (check that the pid is gone);
  - a process that ignores SIGTERM dies after the injected grace period.
- **Tabs:**
  - app tabs follow the sessions and terminals, in open order;
  - one tab per app;
  - saving and restoring gives asleep tabs.
- **Discovery:**
  - a project folder with `.linkc/app.json` lists its app;
  - Settings apps list in every project;
  - a project app hides the Settings app with the same folder.

Checked by hand in the app:
- open Circuit MCP in its project;
- close the tab and check that no Python process remains (`pgrep -f run_ui.py`);
- restart linkC and check that the tab is asleep;
- try a broken manifest.

## Out of scope

- Embedding native (non-web) app windows.
- A JavaScript bridge between the page and linkC.
- Stopping an app while its tab is hidden.
- The Circuit MCP changes (a `{port}` argument, a health path, and its `.linkc/app.json`). These are a separate change in that repo.
- Circuit drawing and simulation.
