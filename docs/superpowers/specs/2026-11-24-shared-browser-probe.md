# Shared Browser Probe for linkC Agents

Date: 2026-11-24
Status: Probe Complete (No application code changes)

## Objective
Evaluate whether multiple agents in one linkC project can share a single headless Chrome browser managed by linkC, with each agent operating in its own pinned tab, avoiding the overhead of launching separate Chrome instances for every agent.

---

## 1. CLI Probe: Headless Chrome, CDP Attachment, and Pinned Tabs

### Setup
We launched a single headless Google Chrome instance (version 158.0.8127.37) on port `9444` with an isolated temporary user-data directory:
```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new \
  --remote-debugging-port=9444 \
  --user-data-dir=/tmp/chrome-probe \
  --no-first-run \
  --no-default-browser-check
```

Initial CDP targets query (`GET http://127.0.0.1:9444/json/list`):
```text
CDP Targets count: 2
  id: F58E50E0F51AD489D1D26679E94E3969 type: page title: New Tab url: chrome://newtab/
  id: 7940C181FFCAA2833268A15439383529 type: browser_ui title: Omnibox Popup url: chrome://omnibox-popup.top-chrome/
```

### Commands Executed & Output

#### 1. Session `s1` attaches and navigates:
```bash
$ agent-browser --cdp 9444 --session s1 --pin-tab open https://example.com
stdout: ✓ Example Domain
  https://example.com/
exit code: 0
```
CDP targets after `s1` navigation:
A page target was created with id `950364792ECE8C0485C8A596DA7AFFD2`, title `Example Domain`, url `https://example.com/`.

#### 2. Session `s2` attaches and navigates:
```bash
$ agent-browser --cdp 9444 --session s2 --pin-tab open https://example.org
stdout: ✓ Example Domain
  https://example.org/
exit code: 0
```
CDP targets after `s2` navigation:
A separate second page target was created with id `056C27D0127A5276B06DD9A091EA9F62`, title `Example Domain`, url `https://example.org/`.

#### 3. Verification of Tab Independence:
```bash
$ agent-browser --session s1 get url
stdout: https://example.com/
exit code: 0

$ agent-browser --session s2 get url
stdout: https://example.org/
exit code: 0
```
Both sessions independently read their respective URLs without cross-tab contamination.

#### 4. Closing Session `s1`:
```bash
$ agent-browser --session s1 close
stdout: ✓ Browser closed
exit code: 0
```
Re-checking CDP targets (`GET http://127.0.0.1:9444/json/list`) after closing `s1`:
```text
CDP Targets after s1 close:
  id: 056C27D0127A5276B06DD9A091EA9F62 type: page title: Example Domain url: https://example.org/
  id: 950364792ECE8C0485C8A596DA7AFFD2 type: page title: Example Domain url: https://example.com/
  id: 94C38022E4F510C3E3C5FCCCCA89B1EE type: page title: about:blank url: about:blank
  ...
```
**Key Finding:** Closing `s1` disconnects the `s1` session daemon, but **leaves its tab (`https://example.com/`) plus an extra `about:blank` tab open in Chrome**. The underlying Chrome process remains running, and `s2` continues to function and read `https://example.org/` normally:
```bash
$ agent-browser --session s2 get url
stdout: https://example.org/
exit code: 0
```

---

## 2. MCP Mode Probe (`agent-browser mcp`)

We evaluated driving `agent-browser mcp` via JSON-RPC stdio against the same Chrome instance running on port `9444`. *(Note: An earlier version of this document mixed up ports 9555 and 9444).*

### Test 2A: Environment Configuration (`AGENT_BROWSER_CDP=9444` & `AGENT_BROWSER_PIN_TAB=1`)
We started `agent-browser mcp` with:
- `AGENT_BROWSER_CDP="9444"`
- `AGENT_BROWSER_PIN_TAB="1"`
- `AGENT_BROWSER_SESSION="mcp_s1"`

We sent JSON-RPC messages via stdin with a 15-second per-read timeout on each read (omitting any read after notifications):

1. **`initialize` request:**
   ```json
   {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test-client", "version": "1.0"}}}
   ```
   **Response:**
   ```json
   {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"instructions":"Use the typed agent_browser_* tools to control a browser. Active MCP tools profile(s): core...","protocolVersion":"2024-11-05","serverInfo":{"name":"agent-browser","title":"agent-browser","version":"0.41.2"}}}
   ```

2. **`notifications/initialized` notification:**
   ```json
   {"jsonrpc": "2.0", "method": "notifications/initialized"}
   ```
   *(No response expected or read for JSON-RPC notifications)*

3. **`tools/list` request:**
   ```json
   {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
   ```
   **Response:**
   Returned 33 tools: `agent_browser_tools_profiles`, `agent_browser_open`, `agent_browser_flow_list`, `agent_browser_flow_run`, `agent_browser_flow_steps`, `agent_browser_snapshot`, `agent_browser_get_url`, etc.

4. **`tools/call` for `agent_browser_open` with `{"url": "https://example.com"}`:**
   ```json
   {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "agent_browser_open", "arguments": {"url": "https://example.com"}}}
   ```
   **Response:**
   ```json
   {"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"Example Domain\n\nwarning: Chrome 158.0.8127.37 is behind the current stable release 158.0.8127.88, which fixes 1 CVEs (CVE-2026-134401). Update the browser; for agent-browser's Chrome, run `agent-browser install`.","type":"text"}],"isError":false,"structuredContent":{"exitCode":0,"response":{"data":{"lifecycle":{"effectiveLaunch":{"browserLaunched":true,"engine":"chrome","launchHash":8187140403112797887},"launched":true,"relaunchedBrowser":false,"restartedBackground":false,"restoreStatus":"not_configured","reused":false,"saveStatus":"not_attempted","settings":{"changes":[{"applied":false,"effect":"relaunch","option":"cdp","requested":"9444","running":null}],"forcedRelaunch":false}},"targetId":"E4B014ED84C77D83B43CD993E9CA6756","title":"Example Domain","url":"https://example.com/"},"error":null,"success":true,"warning":"Chrome 158.0.8127.37 is behind the current stable release 158.0.8127.88, which fixes 1 CVEs (CVE-2026-134401). Update the browser; for agent-browser's Chrome, run `agent-browser install`."},"stderr":""}}}
   ```

5. **`tools/call` for `agent_browser_get_url` with `{}`:**
   ```json
   {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "agent_browser_get_url", "arguments": {}}}
   ```
   **Response:**
   ```json
   {"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"https://example.com/","type":"text"}],"isError":false,"structuredContent":{"exitCode":0,"response":{"data":{"lifecycle":{"effectiveLaunch":{"browserLaunched":true,"engine":"chrome","launchHash":8187140403112797887},"launched":false,"relaunchedBrowser":false,"restartedBackground":false,"restoreStatus":"not_configured","reused":true,"saveStatus":"not_attempted"},"url":"https://example.com/"},"error":null,"success":true},"stderr":""}}}
   ```

6. **Target Verification in Shared Chrome:**
   We immediately queried the shared Chrome instance via `GET http://127.0.0.1:9444/json/list`:
   ```text
   id: E4B014ED84C77D83B43CD993E9CA6756 type: page title: Example Domain url: https://example.com/
   id: A8017FFAD632139ABD918F48D2419D1A type: page title: about:blank url: about:blank
   id: E4786BB3423CD6264C99302AB58E137A type: page title: New Tab url: chrome://newtab/
   id: 6FE948B1BC3B2F06164C5B79070BDA0D type: iframe title: chrome-untrusted://new-tab-page/one-google-bar?paramsencoded= url: chrome-untrusted://new-tab-page/one-google-bar?paramsencoded=
   id: FCECF31D17D6A615081EC8A76E0441AF type: browser_ui title: Omnibox Popup url: chrome://omnibox-popup.top-chrome/
   ...
   ```
   **Attachment Status:** Plainly stated, `agent-browser mcp` **did attach** to the shared Chrome instance running on port 9444. The new page target (`targetId: E4B014ED84C77D83B43CD993E9CA6756`, `url: https://example.com/`) was created and hosted directly inside the shared Chrome process.

   **Understanding `"browserLaunched": true` and `cdp: applied: false`:**
   - `"browserLaunched": true` and `"launched": true` represent `agent-browser`'s session daemon connecting to the browser session for the first time rather than reusing an existing daemon session connection.
   - `settings.changes: [{"applied": false, "effect": "relaunch", "option": "cdp", "requested": "9444", "running": null}]` signifies that because no browser was previously active on this session daemon (`running: null`), applying the CDP port setting did not require relaunching an existing browser.
   - Setting `AGENT_BROWSER_CDP="9444"` in the process environment before starting `agent-browser mcp` is what causes it to attach to the shared instance.

### Test 2B: Passing `extraArgs: ["--cdp", "9444"]` Per Tool Call
We tested whether individual tool calls could specify the CDP port on the fly without setting it in the MCP server process environment:
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "agent_browser_open",
    "arguments": {
      "url": "https://example.org",
      "extraArgs": ["--cdp", "9444"]
    }
  }
}
```

**Response:**
`agent-browser mcp` explicitly rejected the call:
```json
{
  "error": {
    "code": -32602,
    "message": "Tool arguments may not set --cdp; configure it in the MCP server's environment or config"
  },
  "id": 5,
  "jsonrpc": "2.0"
}
```
**Conclusion:** `extraArgs` cannot be used to pass `--cdp`. The CDP port **must** be provided via the MCP server's environment variables or configuration file.

---

## 3. Environment Variable Delivery Across Agents

Each agent supported by linkC receives environment variables and MCP configurations differently:

1. **Claude Code, Cursor, Antigravity (`agy`):**
   - **Mechanism:** Direct process inheritance.
   - Child processes and their spawned MCP servers inherit the terminal's environment variables.
   - **Delivery:** Exporting `AGENT_BROWSER_CDP=<port>`, `AGENT_BROWSER_PIN_TAB=1`, and `AGENT_BROWSER_SESSION=<sessionId>` in the environment when spawning the agent process reaches `agent-browser mcp`.
   - *Unprobed:* Whether Claude Code, Cursor, and `agy` pass their full environment to MCP servers under all operating modes in production.

2. **Codex:**
   - **Mechanism:** Process isolation. Codex's background daemon strips inherited environment variables.
   - **Delivery:** LinkC already injects session variables into Codex via CLI config flags (see `Sources/LinkCKit/Core/AgentKind.swift` line 259):
     ```swift
     args += ["-c", "mcp_servers.\(MCPRegistrar.serverName).env.LINKC_SESSION=\"\(sessionId)\""]
     ```
     For `agent-browser`, the same pattern applies:
     ```swift
     args += [
         "-c", "mcp_servers.agent-browser.env.AGENT_BROWSER_CDP=\"\(cdpPort)\"",
         "-c", "mcp_servers.agent-browser.env.AGENT_BROWSER_PIN_TAB=\"1\"",
         "-c", "mcp_servers.agent-browser.env.AGENT_BROWSER_SESSION=\"\(sessionId)\""
     ]
     ```
   - *Unprobed:* Live execution of multi-session Codex CLI with `--cdp` injection flags.

3. **OpenCode & Kilo:**
   - **Mechanism:** Inline JSON configuration via environment variables (`OPENCODE_CONFIG_CONTENT` and `KILO_CONFIG_CONTENT`), handled by `Sources/LinkCKit/MCP/MCPRegistrar.swift` (`inlineOpenCodeStyleConfigContent`).
   - **Delivery:** OpenCode and Kilo MCP entries define an `environment` map:
     ```json
     {
       "mcp": {
         "agent-browser": {
           "type": "local",
           "command": ["agent-browser", "mcp"],
           "environment": {
             "AGENT_BROWSER_CDP": "<port>",
             "AGENT_BROWSER_PIN_TAB": "1",
             "AGENT_BROWSER_SESSION": "<sessionId>"
           }
         }
       }
     }
     ```
   - *Unprobed:* Live execution of OpenCode and Kilo with inline `AGENT_BROWSER_CDP` configuration.

4. **Crush:**
   - **Mechanism:** Global config file `crush.json` in `~/.config/crush/crush.json` (or `CRUSH_GLOBAL_CONFIG`), managed via `MCPRegistrar.registerCrushServer`.
   - **Delivery:** Defines an `mcp` entry with an `env` dictionary containing `AGENT_BROWSER_CDP`, `AGENT_BROWSER_PIN_TAB`, and `AGENT_BROWSER_SESSION`.
   - *Unprobed:* Live execution of Crush with injected browser MCP settings.

5. **Grok:**
   - **Mechanism:** Runs Cursor's CLI (`cursor-agent`) isolated in `~/.cursor-grok` with `CURSOR_CONFIG_DIR` and `LINKC_WORKER=grok`.
   - **Delivery:** Follows Cursor's process inheritance or config delivery mechanism.
   - *Unprobed:* Live execution of Grok sessions with browser MCP settings.

6. **Freebuff:**
   - **Mechanism:** Configuration file `~/.agents/mcp.json` using the standard `mcpServers` object format with an `env` dictionary.
   - **Delivery:** Configured via `MCPRegistrar.registerFreebuffServer` by adding `AGENT_BROWSER_CDP`, `AGENT_BROWSER_PIN_TAB`, and `AGENT_BROWSER_SESSION` to the server's `env` map.
   - *Unprobed:* Live execution of Freebuff with browser MCP server configuration.

---

## 4. Smallest Viable Design Recommendation

### Architecture
1. **Lifecycle Daemon in linkC:**
   - When a linkC project starts or an agent requests browser access, linkC spawns a single headless Chrome process on a dynamically allocated localhost port (`--remote-debugging-port=<port> --user-data-dir=<project_cache>/chrome`).
   - LinkC terminates the Chrome process when the project terminates.

2. **Environment Injection (Zero CLI Tool Call Hacks):**
   - Because `agent-browser mcp` forbids `--cdp` in `extraArgs`, configure the three variables at MCP registration / agent spawn time:
     - `AGENT_BROWSER_CDP=<port>`
     - `AGENT_BROWSER_PIN_TAB=1`
     - `AGENT_BROWSER_SESSION=<sessionId>` (unique per agent or session to isolate tab state and daemons)
   - Route variables per agent type using linkC's existing mechanisms:
     - **Claude/Cursor/agy/Grok:** Terminal environment dictionary when launching child agent process.
     - **Codex:** Add `-c mcp_servers.agent-browser.env...` arguments in `AgentKind.arguments(for: .codex, ...)`.
     - **OpenCode/Kilo:** Add environment keys in `MCPRegistrar.openCodeConfigContent` / `kiloConfigContent`.
     - **Crush:** Add environment keys in `crush.json` `mcp` table.
     - **Freebuff:** Add environment keys in `~/.agents/mcp.json` `mcpServers` table.

3. **Session Behavior & Tab Cleanup:**
   - With `--pin-tab`, each session opens in its own tab and binds subsequent commands (`get url`, `snapshot`, `click`, etc.) to that tab without affecting other sessions.
   - **Session Tab Cleanup:** As discovered during probing, `agent-browser close` disconnects the session client daemon but leaves the pinned tab (and an extra `about:blank` tab) open in Chrome. linkC must track target IDs belonging to each session and issue explicit CDP `Target.closeTarget` calls when a session ends so abandoned tabs do not accumulate in the shared browser.
