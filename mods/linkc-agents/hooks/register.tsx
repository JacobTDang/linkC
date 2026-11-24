import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionContextUsage } from 'claude-code'

import type { AgentRow, Agents, Meter } from '../types'
import type { ShimmerProps } from './shimmer'

const FILETREE = 'filetree'
const POLL_MS = 2000

// OpenCode's dark palette.
const TEXT = '#eeeeee'
const MUTED = '#808080'
const RULE = '#484848'
const PEACH = '#fab283'
const GREEN = '#7fd88f'
const ORANGE = '#f5a742'
const RED = '#fd7e87'

/**
 * filetree's activity tones: `bright` runs from the tone to near white (the shimmer band), `dim` is
 * the tone at rest.
 */
type Tone = { bright: string[]; dim: string[]; solid: string }
const TONES = {
  orange: { bright: ['#f97316', '#fb923c', '#fdba74', '#ffedd5'], dim: ['#8e491d', '#a3562a', '#bd7444', '#d29267'], solid: '#f97316' },
  green: { bright: ['#22c55e', '#4ade80', '#86efac', '#dcfce7'], dim: ['#2e6644', '#1b6838', '#2f7a47', '#4f9a66'], solid: '#4ade80' },
  teal: { bright: ['#14b8a6', '#2dd4bf', '#5eead4', '#ccfbf1'], dim: ['#1b665f', '#16786f', '#2a9488', '#4fb3a8'], solid: '#2dd4bf' },
  blue: { bright: ['#3b82f6', '#60a5fa', '#93c5fd', '#dbeafe'], dim: ['#40589c', '#1d4ed8', '#3b6fd1', '#6b93dc'], solid: '#60a5fa' },
  purple: { bright: ['#a855f7', '#c084fc', '#d8b4fe', '#f3e8ff'], dim: ['#76459d', '#7d3cb2', '#8b47c4', '#a874d6'], solid: '#c084fc' },
  cyan: { bright: ['#06b6d4', '#22d3ee', '#67e8f9', '#cffafe'], dim: ['#1c6379', '#0e7490', '#2b8ea3', '#5aa9b8'], solid: '#22d3ee' },
  red: { bright: ['#ef4444', '#f87171', '#fca5a5', '#fee2e2'], dim: ['#954343', '#a43434', '#b54040', '#c96a6a'], solid: '#f87171' },
} satisfies Record<string, Tone>
const GREY: Tone = { bright: [MUTED, '#a6a6a6', '#cccccc', '#f2f2f2'], dim: [MUTED, MUTED, MUTED, '#9a9a9a'], solid: '#a6a6a6' }

/** Each agent's tone: its bar, its title, and its working line's shimmer. */
const AGENT_TONE: Record<string, Tone> = {
  claude: TONES.orange,
  codex: TONES.blue,
  agy: TONES.cyan,
  cursor: TONES.purple,
  grok: GREY,
  opencode: TONES.green,
  kilo: TONES.teal,
  crush: TONES.red,
  freebuff: GREY,
}

type StateLook = { glyph: string; label: string; color: string; rank: number; needsYou?: true }

/** The rank of every state at work: working, busy, or running subagents. Its line shimmers. */
const WORKING_RANK = 3


const IDLE: StateLook = { glyph: '○', label: 'idle', color: MUTED, rank: 6 }

/** How a state reads on a card's second line, and where it sorts: what needs you first. */
const STATES: Record<string, StateLook> = {
  waitingPermission: { glyph: '!', label: 'needs permission', color: ORANGE, rank: 0, needsYou: true },
  error: { glyph: '✗', label: 'error', color: RED, rank: 1, needsYou: true },
  waitingIdle: { glyph: '●', label: 'waiting for you', color: ORANGE, rank: 2, needsYou: true },
  working: { glyph: '●', label: 'working', color: GREEN, rank: 3 },
  starting: { glyph: '◌', label: 'starting', color: ORANGE, rank: 4 },
  finished: { glyph: '✓', label: 'done', color: GREEN, rank: 5 },
  ready: { glyph: '○', label: 'ready', color: MUTED, rank: 6 },
  // An older linkC publishes only the coarse activity.
  busy: { glyph: '●', label: 'busy', color: GREEN, rank: 3 },
  idle: IDLE,
}

const agents = atom({ plugin: 'linkc-agents', key: 'agents' } as const, { rows: [], error: null, me: null, minute: 0 }, {
  shape: 'agents-2',
})

const meters = atom({ plugin: 'linkc-agents', key: 'meters' } as const, [], { shape: 'meters-1' })
const isCompacting = atom({ plugin: 'linkc-agents', key: 'isCompacting' } as const, false)

const BAR_CELLS = 8

/**
 * How full the context is, against the point where it auto-compacts when that comes before the
 * window's end, as /context counts it; the plain figure could never reach a warning first.
 */
function contextPercent(context: SessionContextUsage): number | null {
  const compactsAt = context.breakdown?.rawMaxTokens
  if (context.tokens !== undefined && compactsAt !== undefined && compactsAt > 0 && compactsAt < context.window) {
    return Math.min(100, Math.round((context.tokens / compactsAt) * 100))
  }
  return context.percent ?? null
}

/** `seven_day` reads `7d`, `five_hour` `5h`; any other kind as its own words. */
function limitLabel(kind: string): string {
  const name = kind.toLowerCase()
  if (name.includes('five') || name.includes('5h')) return '5h'
  if (name.includes('seven') || name.includes('7d') || name.includes('week')) return '7d'
  return name.replace(/_/g, ' ')
}

async function refreshMeters($: EngineInterface): Promise<void> {
  const usage = await $.session.usage({ breakdown: 'summary' })
  const context = contextPercent(usage.context)
  const now: Meter[] = [
    ...(context === null ? [] : [{ label: 'context', percent: context }]),
    ...usage.rateLimits.map(limit => ({ label: limitLabel(limit.kind), percent: Math.round(limit.percentUsed) })),
  ]
  if (JSON.stringify(now) !== JSON.stringify(await read($, meters))) await update($, meters, () => now)
}

function meterColor(percent: number): string {
  return percent >= 90 ? RED : percent >= 70 ? ORANGE : GREEN
}

type Stored = { projects: { path: string; sessions: Omit<AgentRow, 'where'>[] }[] }

/**
 * The repo `cwd` is in, through its worktrees to the main checkout, as a real path (linkC publishes
 * real paths). A folder outside git is its own repo. Any other git failure throws, so the pane says
 * why rather than quietly showing a narrower repo.
 */
async function repoRoot($: EngineInterface, cwd: string): Promise<string> {
  const run = await $.process.run(['git', '-C', cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { timeoutMs: 5_000 })
  if (run.exitCode === 0) {
    const common = run.stdout.trim()
    return common.endsWith('/.git') ? common.slice(0, -'/.git'.length) : common
  }
  if (!/not a git repository/i.test(run.stderr)) {
    throw new Error(`git cannot read the repo of ${cwd}: ${run.stderr.trim() || `it exited ${run.exitCode}`}`)
  }
  const real = await $.process.run(['/bin/realpath', cwd], { timeoutMs: 5_000 })
  if (real.exitCode !== 0) throw new Error(`cannot resolve ${cwd}: ${real.stderr.trim() || `realpath exited ${real.exitCode}`}`)
  return real.stdout.trim()
}

/** Where a card's session runs, shortly: a worktree's name, else the last folder below the repo. */
function placeOf(where: string): string {
  if (where === '.') return ''
  return /(?:^|\/)\.?worktrees\/([^/]+)/.exec(where)?.[1] ?? where.split('/').pop() ?? ''
}

/** Where `path` sits in `root`: '.' for the root itself, its relative path below it, null outside it. */
function within(root: string, path: string): string | null {
  if (path === root) return '.'
  return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : null
}

/**
 * A model as a person reads it. A name the agent already gave (`Opus 5.5`) stays; a Claude id reads
 * as its family and version (`claude-opus-5-5` → `Opus 5.5`); any other id keeps its name and
 * version joined and spaces the rest (`gemini-3.8-flash-medium` → `gemini-3.8 flash medium`).
 */
export function modelLabel(model: string): string {
  if (/[A-Z ]/.test(model)) return model
  const named = (family: string, major: string, minor: string | undefined) =>
    `${family.charAt(0).toUpperCase()}${family.slice(1)} ${major}${minor ? `.${minor}` : ''}`
  // claude-opus-5-5, claude-opus-4-20250514 (no minor, a date), and the older claude-3-5-sonnet-20241022.
  const current = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/.exec(model)
  if (current) return named(current[1]!, current[2]!, current[3])
  const older = /^claude-(\d+)(?:-(\d{1,2}))?-([a-z]+)(?:-\d{8})?$/.exec(model)
  if (older) return named(older[3]!, older[1]!, older[2])
  const parts = model.split('-')
  const version = parts.findIndex(part => /^\d+(\.\d+)*$/.test(part))
  if (version < 0) return model
  return [parts.slice(0, version + 1).join('-'), ...parts.slice(version + 1)].join(' ')
}

/** Shows a session in linkC as its tab would, through its `linkc://session/<id>` link. */
async function openSession($: EngineInterface, id: string): Promise<void> {
  const url = `linkc://session/${id}`
  try {
    const run = await $.process.run(['open', url], { timeoutMs: 5_000 })
    if (run.exitCode !== 0) $.ui.toast(`linkC could not open the session: ${run.stderr.trim() || `open exited ${run.exitCode}`}`)
  } catch (error) {
    $.ui.toast(`linkC could not open the session: ${error instanceof Error ? error.message : String(error)}`)
  }
}

function subagentWords(count: number): string {
  return `${count} subagent${count === 1 ? '' : 's'}`
}

/**
 * How a card's state reads. A session whose own turn ended while its subagents still run is at
 * work, not idle or waiting; a permission wait or an error still comes first.
 */
/** A turn running now, as linkC's state or, from an older linkC, its coarse activity says. */
function isAtWork(row: AgentRow): boolean {
  const known = row.state !== undefined && row.state in STATES
  return row.state === 'working' || (!known && row.activity === 'busy')
}

/**
 * A card's second line. A session at work shows what it does — its action, or its running
 * subagents — never the word for its state: the dot and the shimmer already say it works.
 */
function detailOf(row: AgentRow, state: StateLook): string {
  const subagents = row.subagents ? subagentWords(row.subagents) : ''
  const words = row.action
    ? [row.action, subagents].filter(Boolean).join(' · ')
    : isAtWork(row) ? (subagents ? `running ${subagents}` : '') : state.label
  const where = placeOf(row.where)
  return [words, where].filter(Boolean).join(' ')
}

/** When the card's prompt cache goes cold: `~` marks a guess, orange the last five minutes. */
function cacheLabel(row: AgentRow, now: number): { text: string; color: string } | null {
  if (!row.cacheExpiresAt) return null
  const left = Date.parse(row.cacheExpiresAt) - now
  if (Number.isNaN(left)) return null
  if (left <= 0) return { text: ' ◷ cold', color: RED }
  const minutes = Math.ceil(left / 60_000)
  const span = minutes >= 60 ? `${Math.floor(minutes / 60)}h` : `${minutes}m`
  return { text: ` ◷ ${row.cacheEstimate ? '~' : ''}${span}`, color: minutes <= 5 ? ORANGE : MUTED }
}

function stateOf(row: AgentRow): StateLook {
  // A state a newer linkC publishes that this mod does not know reads by the coarse activity.
  const known = row.state !== undefined && row.state in STATES
  const look = (known ? STATES[row.state!] : STATES[row.activity]) ?? IDLE
  const running = row.subagents ?? 0
  if (running === 0 || isAtWork(row) || row.state === 'waitingPermission' || row.state === 'error') return look
  return { glyph: '●', label: `running ${subagentWords(running)}`, color: GREEN, rank: 3 }
}

async function load($: EngineInterface, file: string, root: string): Promise<Pick<Agents, 'rows' | 'error'>> {
  try {
    const stored = JSON.parse(await $.fs.read(file)) as Stored
    const rows: AgentRow[] = stored.projects.flatMap(p => {
      const where = within(root, p.path)
      return where === null ? [] : p.sessions.map(s => ({ ...s, where }))
    })
    rows.sort((a, b) => stateOf(a).rank - stateOf(b).rank || (a.title ?? a.agent).localeCompare(b.title ?? b.agent))
    return { rows, error: null }
  } catch (err) {
    return { rows: [], error: `cannot read ${file}: ${String(err)}` }
  }
}

function age(since: string | undefined, now: number): string {
  if (!since) return ''
  const minutes = Math.floor((now - Date.parse(since)) / 60_000)
  if (!(minutes >= 1)) return 'now'
  if (minutes < 60) return `${minutes}m`
  if (minutes < 60 * 24) return `${Math.floor(minutes / 60)}h`
  return `${Math.floor(minutes / (60 * 24))}d`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const file = `${await $.env.get('HOME')}/Library/Application Support/linkC/projects.json`
    const me = (await $.env.get('LINKC_SESSION')) || null
    let last = ''
    let cwd = ''
    let root = ''
    let isRefreshing = false
    const show = async (now: Agents) => {
      const key = JSON.stringify(now)
      if (key === last) return
      last = key
      await update($, agents, () => now)
    }
    // One at a time: a slow git run must not let an older refresh write after a newer one.
    const refresh = async () => {
      if (isRefreshing) return
      isRefreshing = true
      // The minute is in the value so the ages redraw once a minute even when nothing else changed.
      const minute = Math.floor(Date.now() / 60_000)
      try {
        const here = await $.session.cwd()
        if (here !== cwd) {
          root = await repoRoot($, here)
          cwd = here
        }
        await show({ ...(await load($, file, root)), me, minute })
      } catch (error) {
        await show({ rows: [], error: error instanceof Error ? error.message : String(error), me, minute })
      } finally {
        isRefreshing = false
      }
    }
    // Armed before the first refresh, so a first refresh that fails is tried again.
    $.clock.every(POLL_MS, () => void refresh())
    await refresh()
    try {
      await refreshMeters($)
    } catch (error) {
      $.ui.toast(`linkc-agents could not read this session's usage: ${error instanceof Error ? error.message : String(error)}`)
    }
    return next(e)
  })

  // A turn's end and a plan limit's move are when the meters change.
  on('session.measure', async ($, e, next) => {
    await refreshMeters($)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) await refreshMeters($)
    return next(e)
  })

  // The band above the prompt: every meter in one box, label, bar and padded percent, so the
  // columns line up whatever the numbers; Compact beside it while no turn runs.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const shown = await read($, meters)
    if (e.props.hasSurvey || shown.length === 0) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const canCompact = !e.props.isWorking && !(await read($, isCompacting))
    // Compacting from the press would end with the press; a timer gives it a dispatch of its own.
    const compact = () => {
      void update($, isCompacting, () => true)
      $.clock.after(1, () =>
        $.command
          .run({ command: 'compact' })
          .catch((error: unknown) => $.ui.toast(`Compacting failed: ${error instanceof Error ? error.message : String(error)}`))
          .finally(() => update($, isCompacting, () => false)),
      )
    }

    return (
      <Box flexDirection="row" alignItems="center" columnGap={2}>
        <Box flexDirection="row" borderStyle="round" borderColor={RULE} paddingX={1} columnGap={3}>
          {shown.map(meter => {
            const filled = Math.min(BAR_CELLS, Math.round((meter.percent / 100) * BAR_CELLS))
            return (
              <Box flexDirection="row" columnGap={1}>
                <Text color={MUTED}>{meter.label}</Text>
                <Text color={meterColor(meter.percent)}>{'▰'.repeat(filled) + '▱'.repeat(BAR_CELLS - filled)}</Text>
                <Text color={TEXT}>{`${meter.percent}%`.padStart(4)}</Text>
              </Box>
            )
          })}
        </Box>
        {canCompact && <Button key="compact" label="Compact" hotkey="0" plain dimColor onPress={compact} />}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', plugin: '*', requestId: FILETREE }, async ($, e, next) => {
    const elements = $.ui.resolve(e)
    const { Box, Text, Button } = elements
    // Only the terminal and the desktop app run client modules; elsewhere the line stays still.
    const Client = 'Client' in elements ? elements.Client : undefined
    const body = e.props.scroll?.bodyRows ?? 40
    const width = e.props.bodyColumns
    const top = Math.max(5, Math.floor(body / 2))
    const tree = await next({ ...e, props: { ...e.props, scroll: e.props.scroll && { ...e.props.scroll, bodyRows: top } } })
    const { rows, error, me } = await read($, agents)
    const now = Date.now()
    // A rule, the header and a blank line, then three rows a card: its two lines and a gap.
    const fits = Math.max(1, Math.floor((body - top - 3 + 1) / 3))
    const shown = rows.length > fits ? rows.slice(0, fits - 1) : rows
    const needsYou = rows.filter(row => stateOf(row).needsYou).length

    return (
      <Box flexDirection="column">
        <Box flexDirection="column" height={top} overflow="hidden">
          {tree}
        </Box>
        <Text color={RULE}>{'─'.repeat(width)}</Text>
        <Box flexDirection="row">
          <Text bold color={TEXT}>{' linkC'}</Text>
          <Text color={MUTED}>{' agents'}</Text>
          <Box flexGrow={1} />
          {needsYou > 0 && <Text bold color={ORANGE}>{`${needsYou} need you  `}</Text>}
          <Text color={MUTED}>{`${rows.length} `}</Text>
        </Box>
        <Text> </Text>
        {error && <Text color={RED} wrap="truncate-end">{` ${error}`}</Text>}
        {!error && rows.length === 0 && <Text color={MUTED}>{' No sessions in this repo.'}</Text>}
        {shown.map(row => {
          const tone = AGENT_TONE[row.agent] ?? GREY
          const bar = tone.solid
          const state = stateOf(row)
          // A card at work or waiting on you is in its full tone; one at rest is dimmed.
          const titleColor = state.rank <= WORKING_RANK ? tone.solid : (tone.dim[3] ?? MUTED)
          const isMe = row.id === me
          const detail = detailOf(row, state)
          const cache = cacheLabel(row, now)
          return (
            <Box flexDirection="column">
              <Box flexDirection="row">
                <Box flexGrow={1} flexShrink={1}>
                  <Button key={`open-${row.id}`} plain onPress={() => openSession($, row.id)}>
                    <Text color={bar}>{'┃ '}</Text>
                    <Text bold color={titleColor} wrap="truncate-end">{row.title ?? row.agent}</Text>
                  </Button>
                </Box>
                <Text color={MUTED}>{`${row.model ? ` ${modelLabel(row.model)}` : row.title ? ` ${row.agent}` : ''}${row.worker ? ' · worker' : ''}`}</Text>
                {cache && <Text color={cache.color}>{cache.text}</Text>}
                {isMe && <Text bold color={PEACH}>{' · you'}</Text>}
                <Text> </Text>
              </Box>
              <Box flexDirection="row">
                {/* Fixed cells, so a line that has to shrink never eats the space after the bar or the dot. */}
                <Box width={2} flexShrink={0}>
                  <Text color={bar}>{'┃'}</Text>
                </Box>
                <Box width={2} flexShrink={0}>
                  <Text bold={state.needsYou} color={state.color}>{state.glyph}</Text>
                </Box>
                <Box flexGrow={1} flexShrink={1}>
                  {state.rank === WORKING_RANK && Client ? (
                    <Client key={`shimmer-${row.id}`} module="./shimmer.tsx" props={{ text: detail, palette: tone.bright } satisfies ShimmerProps} />
                  ) : (
                    <Text color={state.needsYou ? state.color : MUTED} wrap="truncate-end">{detail}</Text>
                  )}
                </Box>
                <Text color={MUTED}>{` ${age(row.since, now)} `}</Text>
              </Box>
              <Text> </Text>
            </Box>
          )
        })}
        {shown.length < rows.length && <Text color={MUTED}>{`   +${rows.length - shown.length} more`}</Text>}
      </Box>
    )
  })
}
