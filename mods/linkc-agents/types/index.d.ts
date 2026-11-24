/** One live session linkC publishes in projects.json; the row details are absent from an older linkC. */
export type AgentRow = {
  id: string
  agent: string
  /** Where it runs in the repo: '.' for the repo root, else its path below it. */
  where: string
  activity: string
  title?: string
  state?: string
  since?: string
  model?: string
  worker?: boolean
  action?: string
  subagents?: number
  cacheExpiresAt?: string
  cacheEstimate?: boolean
}

/** What the bottom half shows: the repo's sessions, or why they could not be read. */
export type Agents = { rows: AgentRow[]; error: string | null; me: string | null; minute: number }

/** One meter in the band above the prompt: `context`, or a plan limit such as `7d`. */
export type Meter = { label: string; percent: number }

declare module 'claude-code' {
  interface PluginState {
    'linkc-agents': { agents: Shaped<Agents>; meters: Shaped<Meter[]>; isCompacting: boolean }
  }
}
