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
  id: F66E12138D8D8A104E15776135EC4ABA type: page title: New Tab url: chrome://newtab/
  id: 5543828596E1DAA671E4CBF7C8B65687 type: browser_ui title: Omnibox Popup url: chrome://omnibox-popup.top-chrome/
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
A new page target was created with id `D1A7076A4D51654180EAC310C83BB99D`, title `Example Domain`, url `https://example.com/`.

#### 2. Session `s2` attaches and navigates:
```bash
$ agent-browser --cdp 9444 --session s2 --pin-tab open https://example.org
stdout: ✓ Example Domain
  https://example.org/
exit code: 0
```
CDP targets after `s2` navigation:
A separate second page target was created with id `6F6E6EBEEF1CC99D58C9DE927D02A135`, title `Example Domain`, url `https://example.org/`.

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

$ agent-browser --session s2 get url
stdout: https://example.org/
exit code: 0
```
Closing `s1` disconnected the `s1` session daemon. Crucially, the underlying Chrome process remained running, and `s2` continued to function and read `https://example.org/` normally.

---

## 2. MCP Mode Probe (`agent-browser mcp`)

We evaluated driving `agent-browser mcp` via JSON-RPC stdio against the running Chrome instance.

### Test 2A: Environment Configuration (`AGENT_BROWSER_CDP` & `AGENT_BROWSER_PIN_TAB=1`)
We started `agent-browser mcp` with:
- `AGENT_BROWSER_CDP="9555"`
- `AGENT_BROWSER_PIN_TAB="1"`
- `AGENT_BROWSER_SESSION="mcp_s1"`

We sent JSON-RPC messages via stdin:
1. `initialize`
2. `notifications/initialized`
3. `tools/list`
4. `tools/call` for `agent_browser_open` with `{"url": "https://example.com"}`
5. `tools/call` for `agent_browser_get_url` with `{}`

**Result:**
- `agent_browser_open` attached cleanly to Chrome on port 9555 and pinned a tab.
- `agent_browser_get_url` returned:
  ```json
  {"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"https://example.com/","type":"text"}],"isError":false}}
  ```
- Target was verified in Chrome CDP: `id: A94A2DBF... type: page title: Example Domain url: https://example.com/`.

### Test 2B: Passing `extraArgs: ["--cdp", "<port>"]` Per Tool Call
We tested whether individual tool calls could specify the CDP port on the fly without setting it in the MCP server process environment:
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "agent_browser_open",
    "arguments": {
      "url": "https://example.org",
      "extraArgs": ["--cdp", "9555"]
    }
  }
}
```

**Result:**
`agent-browser mcp` explicitly rejected the call:
```json
{
  "error": {
    "code": -32602,
    "message": "Tool arguments may not set --cdp; configure it in the MCP server's environment or config"
  },
  "id": 2,
  "jsonrpc": "2.0"
}
```
**Conclusion:** `extraArgs` cannot be used to pass `--cdp`. The CDP port **must** be provided via the MCP server's environment variables or configuration file.

---

## 3. Environment Variable Delivery Across Agents

Each agent supported by linkC receives environment variables differently:

1. **Claude Code, Cursor, Antigravity (`agy`):**
   - **Mechanism:** Direct process inheritance.
   - Child processes and their spawned MCP servers inherit the terminal's environment variables.
   - **Delivery:** Exporting `AGENT_BROWSER_CDP=<port>`, `AGENT_BROWSER_PIN_TAB=1`, and `AGENT_BROWSER_SESSION=<sessionId>` in the environment when spawning the agent process reaches `agent-browser mcp`.

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

3. **OpenCode & Kilo:**
   - **Mechanism:** Inline JSON configuration via environment variables (`OPENCODE_CONFIG_CONTENT` and `KILO_CONFIG_CONTENT`), handled by `Sources/LinkCKit/MCP/MCPRegistrar.swift` (~lines 234-297: `inlineOpenCodeStyleConfigContent`).
   - **Delivery:** OpenCode and Kilo MCP entries define an `environment` map. LinkC can populate:
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

---

## 4. Smallest Viable Design Recommendation

### Architecture
1. **Lifecycle Daemon in linkC:**
   - When a linkC project starts or an agent requests browser access, linkC spawns a single headless Chrome process on a dynamically allocated localhost port (`--remote-debugging-port=<port> --user-data-dir=<project_cache>/chrome`).
   - LinkC terminates the Chrome process when the project/session terminates.

2. **Environment Injection (Zero CLI Tool Call Hacks):**
   - Because `agent-browser mcp` forbids `--cdp` in `extraArgs`, configure the three variables at MCP registration / agent spawn time:
     - `AGENT_BROWSER_CDP=<port>`
     - `AGENT_BROWSER_PIN_TAB=1`
     - `AGENT_BROWSER_SESSION=<sessionId>` (unique per agent or session to isolate tab state and daemons)
   - Route variables per agent type using linkC's existing mechanisms:
     - **Claude/Cursor/agy:** Terminal environment dictionary when launching child agent process.
     - **Codex:** Add `-c mcp_servers.agent-browser.env...` arguments in `AgentKind.arguments(for: .codex, ...)`.
     - **OpenCode/Kilo:** Add environment keys in `MCPRegistrar.openCodeConfigContent` / `kiloConfigContent`.

3. **Session Behavior:**
   - With `--pin-tab`, each session opens in its own tab, binds subsequent commands (`get url`, `snapshot`, `click`, etc.) to that tab, and closing a session disconnects that agent's session without killing the shared Chrome instance or affecting other agents' tabs.
