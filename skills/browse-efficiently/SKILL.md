---
name: browse-efficiently
description: Efficient browser and web usage guide for agents. Use whenever fetching URLs, browsing web pages, scraping documentation, interacting with web apps, or deciding whether to read page text or take screenshots.
---

# Browse Efficiently

High-efficiency patterns for web access. Minimize token cost, latency, and resource footprint across all browsing tasks.

## 1. Public Pages (Read-Only)

When you only need to read content from a public URL, fetch text directly without launching Chrome:

- **Command:** `agent-browser read <url>`
  - Fetches page content as clean markdown with zero Chrome overhead.
  - Narrow content with `--outline` for a compact heading outline: `agent-browser read <url> --outline`
  - Filter specific sections with `--filter <text>`: `agent-browser read <url> --filter <text>`
- If your environment provides a specialized scraping or webfetch tool, prefer that over spinning up a browser.

## 2. Interactive Pages & Rendered DOM

When interaction is required (forms, logins, clicking elements, Single Page Apps):

- Navigate to the page: `agent-browser open <url>`
- **Rendered DOM Reading:** If `agent-browser read <url>` cannot render the page (e.g. client-rendered SPA or authenticated page), omit the URL to read the active tab's rendered DOM:
  - `agent-browser read`
- **Inspect interactive elements and obtain `@refs` to act on:**
  - `agent-browser snapshot -i` (filters for interactive elements; note that `-i` drops body prose)
- **Read page text and prose:**
  - Plain snapshot: `agent-browser snapshot` (preserves visible text and structure)
  - Full body text: `agent-browser get text body`
  - Extract text content from specific elements: `agent-browser get text <selector>` (e.g. `agent-browser get text @e1` or `agent-browser get text "#content"`)
- **Act directly on element references:** `agent-browser click @e1`, `agent-browser fill @e2 "text"`
- Cap token consumption by passing `--max-output <chars>` (e.g., `agent-browser snapshot --max-output 2000`).

## 3. Screenshots: Visual Questions Only

- **Never** take screenshots to read text or table data. Text extraction via `agent-browser read`, plain `snapshot`, or `get text body` is orders of magnitude faster and consumes fewer tokens (`snapshot -i` drops prose, returning only interactive elements).
- **Only** capture screenshots when answering visual questions:
  - Verifying visual layout or alignment
  - Inspecting CSS styling or responsive design
  - Evaluating rendered images, charts, or canvas graphics
  - Command: `agent-browser screenshot [path]`

## 4. Session Lifecycle & Reuse

- **Reuse one browser session** across all interaction steps in a task instead of opening a new browser instance per step.
- Target an explicit session if needed: `agent-browser --session <name> open <url>`
- **Always close the browser session** when your task finishes:
  - `agent-browser close` (or `agent-browser close --session <name>`)

## 5. Delegate Heavy Browsing to Cheaper Agents

- If a task involves extensive web browsing (multi-page research, deep scraping, site crawling), do not burn high-capability model context on page iteration.
- Delegate the browsing work to a cheaper peer or worker session using `linkc_delegate_task`. Note that `linkc_delegate_task` is an MCP tool provided by linkC and only exists in sessions that linkC runs:
  ```json
  {
    "to": "claude",
    "tier": "light",
    "prompt": "Fetch and summarize the documentation from https://docs.example.com"
  }
  ```
  Pass the required `to` (peer agent kind, e.g. `claude`, `cursor`, `opencode`) and `prompt`, and specify `tier: "light"` so the delegated task runs on an inexpensive model. Consume only the returned summary text.
