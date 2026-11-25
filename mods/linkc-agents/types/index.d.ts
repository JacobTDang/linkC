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
  /** How full its context is, 0–100, as its agent reports it. */
  contextPercent?: number
  /** The step its turn is on, as its agent's own hooks or files record it. */
  step?: string
  /** Its running subagents, each by name and the step its files record. */
  subagentSteps?: { name: string; step?: string }[]
}

/** One plan limit of an agent, as linkC publishes it beside the projects. */
export type Limit = { label: string; percent: number; resets?: string }

/** What the bottom half shows: the repo's sessions, or why they could not be read. */
export type Agents = {
  rows: AgentRow[]
  /** Each agent's plan limits, by agent. */
  limits: Record<string, Limit[]>
  error: string | null
  me: string | null
  minute: number
  coldCaches: number
}

/** One meter in the band above the prompt: `context`, or a plan limit such as `7d`. */
export type Meter = { label: string; percent: number }

/** What this session itself is doing right now: whether its turn runs, its last step, and each running subagent's. */
export type SelfActivity = { isTurning: boolean; main: string | null; subagents: { id: string; name: string; activity: string | null }[] }

declare module 'claude-code' {
  interface PluginState {
    'linkc-agents': { agents: Shaped<Agents>; meters: Shaped<Meter[]>; isCompacting: boolean; self: Shaped<SelfActivity> }
  }
}
