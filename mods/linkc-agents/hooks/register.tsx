import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { AgentRow, Agents } from '../types'

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

const AGENT_COLOR: Record<string, string> = {
  claude: PEACH,
  codex: '#5c9cf5',
  agy: '#68d0dd',
  cursor: '#9d83d4',
  grok: TEXT,
  opencode: GREEN,
  kilo: '#e5c07b',
  crush: RED,
  freebuff: MUTED,
}

type StateLook = { glyph: string; label: string; color: string; rank: number; needsYou?: true }

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

type Stored = { projects: { path: string; sessions: Omit<AgentRow, 'where'>[] }[] }

/** The repo `cwd` is in, through its worktrees to the main checkout; a folder outside git is its own. */
async function repoRoot($: EngineInterface, cwd: string): Promise<string> {
  const run = await $.process.run(['git', '-C', cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { timeoutMs: 5_000 })
  const common = run.exitCode === 0 ? run.stdout.trim() : ''
  return common.endsWith('/.git') ? common.slice(0, -'/.git'.length) : cwd
}

/** Where `path` sits in `root`: '.' for the root itself, its relative path below it, null outside it. */
function within(root: string, path: string): string | null {
  if (path === root) return '.'
  return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : null
}

function stateOf(row: AgentRow): StateLook {
  return STATES[row.state ?? row.activity] ?? IDLE
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
    const refresh = async () => {
      const here = await $.session.cwd()
      if (here !== cwd) {
        root = await repoRoot($, here)
        cwd = here
      }
      // The minute is in the value so the ages redraw once a minute even when nothing else changed.
      const now: Agents = { ...(await load($, file, root)), me, minute: Math.floor(Date.now() / 60_000) }
      const key = JSON.stringify(now)
      if (key === last) return
      last = key
      await update($, agents, () => now)
    }
    await refresh()
    $.clock.every(POLL_MS, () => void refresh())
    return next(e)
  })

  on('ui.render', { component: 'Pane', plugin: '*', requestId: FILETREE }, async ($, e, next) => {
    const { Box, Text } = $.ui.resolve(e)
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
          const bar = AGENT_COLOR[row.agent] ?? MUTED
          const state = stateOf(row)
          const isMe = row.id === me
          const where = row.where === '.' ? '' : ` ${row.where.split('/').pop()}`
          return (
            <Box flexDirection="column">
              <Box flexDirection="row">
                <Text color={bar}>{'┃ '}</Text>
                <Box flexGrow={1} flexShrink={1}>
                  <Text bold color={TEXT} wrap="truncate-end">{row.title ?? row.agent}</Text>
                </Box>
                <Text color={MUTED}>{`${row.title ? ` ${row.agent}` : ''}${row.worker ? ' · worker' : ''}`}</Text>
                {isMe && <Text bold color={PEACH}>{' · you'}</Text>}
                <Text> </Text>
              </Box>
              <Box flexDirection="row">
                <Text color={bar}>{'┃ '}</Text>
                <Text bold={state.needsYou} color={state.color}>{`${state.glyph} `}</Text>
                <Box flexGrow={1} flexShrink={1}>
                  <Text color={state.needsYou ? state.color : MUTED} wrap="truncate-end">{`${row.action ?? state.label}${where}`}</Text>
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
