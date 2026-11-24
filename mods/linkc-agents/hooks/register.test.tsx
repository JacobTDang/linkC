import type { On, SessionContextBreakdown } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { modelLabel } from './register'
import { shimmerColor } from './shimmer'

const HOME = '/Users/me'
const FILE = `${HOME}/Library/Application Support/linkC/projects.json`

const PANE = {
  plugin: 'linkc-agents',
  component: 'Pane',
  requestId: 'filetree',
  surface: 'terminal',
  props: {
    title: 'Files',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 46 },
    view: {},
  },
} as const

const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString()

const PROJECTS = {
  projects: [
    {
      path: '/repo',
      sessions: [
        { id: 'IDLE', agent: 'codex', activity: 'idle', title: 'Idle one', state: 'ready', since: minutesAgo(12) },
        { id: 'FAN', agent: 'claude', activity: 'idle', title: 'Fan out', state: 'finished', since: minutesAgo(2), subagents: 2 },
        { id: 'ME', agent: 'claude', activity: 'busy', title: 'Multi-provider', state: 'working', since: minutesAgo(4), action: 'Running the suite', model: 'Opus 5.5' },
      ],
    },
    {
      path: '/repo/.worktrees/fix',
      sessions: [
        { id: 'ASK', agent: 'agy', activity: 'busy', title: 'Fix default', state: 'waitingPermission', since: minutesAgo(1), worker: true, model: 'gemini-3.8-flash-medium' },
      ],
    },
    { path: '/other', sessions: [{ id: 'ELSE', agent: 'cursor', activity: 'busy', title: 'Elsewhere', state: 'working' }] },
  ],
}

const ran =(exitCode: number, stdout: string, stderr = '') =>
  ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })

/** What a process run answers: git finds /repo by default; a test can answer otherwise. */
type Runner = (argv: readonly string[]) => ReturnType<typeof ran> | { deny: string }

/** The engine around the mod: home, this session's id, its folder in /repo, and linkC's file. */
function engine(on: On, file: string | Error, seen: { bodyRows?: number; runs?: string[][] } = {}, run?: Runner) {
  const clock = mock.clock(on)
  on('env.get', (_, e) => ({ value: { HOME, LINKC_SESSION: 'ME' }[e.name] }))
  on('session.cwd', () => ({ value: '/repo/Sources' }))
  on('process.run', (_, e) => {
    seen.runs?.push([...e.argv])
    return run ? run(e.argv) : ran(0, '/repo/.git\n')
  })
  on('fs.read', (_, e) => {
    if (e.path !== FILE) return { deny: `unexpected read of ${e.path}` }
    if (file instanceof Error) return { deny: file.message }
    return { value: file }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  // filetree's own drawing, beneath the mod.
  on('ui.render', { component: 'Pane', plugin: '*' }, ($, e) => {
    seen.bodyRows = e.props.scroll?.bodyRows
    const { Text } = $.ui.resolve(e)
    return <Text>TREE</Text>
  })
  return clock
}

const texts = async (ui: { findAll: (q: { type: 'Text' }) => Promise<readonly { text: string }[]> }) =>
  (await ui.findAll({ type: 'Text' })).map(t => t.text)

test('the tree gets the top half and the repo’s sessions the bottom, what needs you first', async ($, on) => {
  const seen: { bodyRows?: number } = {}
  engine(on, JSON.stringify(PROJECTS), seen)
  await $.session.start({ cwd: '/repo/Sources', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const all = await texts(ui)

  expect(seen.bodyRows).toBe(23)
  expect(all).toContain('TREE')
  const titles = all.filter(t => ['Fix default', 'Multi-provider', 'Idle one', 'Elsewhere'].includes(t))
  expect(titles).toEqual(['Fix default', 'Multi-provider', 'Idle one'])
  expect(all).toContain('1 need you  ')
  await ui.unmount()
})

test('a card reads its action or state, where it runs, its age, and marks this session', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  await $.session.start({ cwd: '/repo/Sources', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const all = await texts(ui)
  const shimmering = (await ui.findAll({ type: 'Client' })).map(c => (c.props.props as { text?: string }).text)

  expect(shimmering).toContain('Running the suite')
  expect(all).toContain('needs permission fix')
  expect(all).toContain(' gemini-3.8 flash medium · worker')
  expect(all).toContain(' Opus 5.5')
  expect(all).toContain(' codex')
  expect(all).toContain(' · you')
  expect(all).toContain(' 4m ')
  expect(all).toContain(' 12m ')
})

test('pressing a card’s title opens that session in linkC', async ($, on) => {
  const seen: { runs: string[][] } = { runs: [] }
  engine(on, JSON.stringify(PROJECTS), seen)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  await ui.press({ key: 'open-ASK' })

  expect(seen.runs).toContainEqual(['open', 'linkc://session/ASK'])
  await ui.unmount()
})

test('a working card’s action shimmers; an idle card’s state does not', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const shimmering = (await ui.findAll({ type: 'Client' })).map(c => (c.props.props as { text?: string }).text)

  expect(shimmering).toContain('Running the suite')
  expect(shimmering).not.toContain('ready')
  expect(await texts(ui)).toContain('ready')
  await ui.unmount()
})

test('the shimmer band sweeps along the text, brightest at its centre', () => {
  const palette = ['d0', 'd1', 'd2', 'd3']
  expect(shimmerColor(5, 0, 20, palette)).toBe('d0')
  const band = Array.from({ length: 20 }, (_, i) => shimmerColor(i, 5, 20, palette))
  expect(band.filter(c => c === 'd3').length).toBe(1)
  expect(band.indexOf('d3')).toBe(4)
})

test('when git cannot run, the pane says so and keeps trying', async ($, on) => {
  let attempts = 0
  const clock = engine(on, JSON.stringify(PROJECTS), {}, argv =>
    argv[0] === 'git' && ++attempts === 1 ? { deny: 'git timed out' } : ran(0, '/repo/.git\n'))
  await $.session.start({ cwd: '/repo/Sources', surface: 'terminal', isInteractive: true })

  const first = await $.ui.mount(PANE)
  expect((await texts(first)).some(t => t.includes('git timed out'))).toBe(true)
  await first.unmount()

  await clock.advance(2_000)
  expect(await texts(await $.ui.mount(PANE))).toContain('Idle one')
})

test('git failing for another reason says so instead of narrowing the repo', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS), {}, () => ran(128, '', 'fatal: detected dubious ownership in repository at /repo\n'))
  await $.session.start({ cwd: '/repo/Sources', surface: 'terminal', isInteractive: true })

  const all = await texts(await $.ui.mount(PANE))
  expect(all.some(t => t.includes('dubious ownership'))).toBe(true)
  expect(all).not.toContain(' No sessions in this repo.')
})

test('a folder outside git is its own repo, matched by its real path', async ($, on) => {
  const projects = { projects: [{ path: '/private/scratch', sessions: [{ id: 'S', agent: 'codex', activity: 'idle', title: 'Scratch' }] }] }
  engine(on, JSON.stringify(projects), {}, argv =>
    argv[0] === 'git'
      ? ran(128, '', 'fatal: not a git repository (or any of the parent directories): .git\n')
      : ran(0, '/private/scratch\n'))
  await $.session.start({ cwd: '/repo/Sources', surface: 'terminal', isInteractive: true })

  expect(await texts(await $.ui.mount(PANE))).toContain('Scratch')
})

test('a state this mod does not know reads by the coarse activity', async ($, on) => {
  const projects = { projects: [{ path: '/repo', sessions: [{ id: 'S', agent: 'claude', activity: 'busy', state: 'compacting', title: 'Squeeze', action: 'Compacting' }] }] }
  engine(on, JSON.stringify(projects))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const shimmering = (await ui.findAll({ type: 'Client' })).map(c => (c.props.props as { text?: string }).text)
  expect(shimmering).toContain('Compacting')
  await ui.unmount()
})

test('a session in a worktree shows the worktree’s name', async ($, on) => {
  const projects = {
    projects: [
      { path: '/repo/.worktrees/fix/Sources', sessions: [{ id: 'A', agent: 'agy', activity: 'idle', title: 'A', state: 'ready' }] },
      { path: '/repo/.claude/worktrees/feat', sessions: [{ id: 'B', agent: 'cursor', activity: 'idle', title: 'B', state: 'ready' }] },
    ],
  }
  engine(on, JSON.stringify(projects))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const all = await texts(await $.ui.mount(PANE))
  expect(all).toContain('ready fix')
  expect(all).toContain('ready feat')
})

test('a card says when its prompt cache goes cold, marking a guess and a cold one', async ($, on) => {
  const inMinutes = (m: number) => new Date(Date.now() + m * 60_000).toISOString()
  const projects = {
    projects: [{
      path: '/repo',
      sessions: [
        { id: 'A', agent: 'claude', activity: 'idle', title: 'Exact', state: 'finished', cacheExpiresAt: inMinutes(3) },
        { id: 'B', agent: 'codex', activity: 'idle', title: 'Guessed', state: 'finished', cacheExpiresAt: inMinutes(30), cacheEstimate: true },
        { id: 'C', agent: 'claude', activity: 'idle', title: 'Cold', state: 'finished', cacheExpiresAt: inMinutes(-10) },
        { id: 'D', agent: 'agy', activity: 'idle', title: 'Unknown', state: 'finished' },
      ],
    }],
  }
  engine(on, JSON.stringify(projects))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const all = await texts(await $.ui.mount(PANE))

  expect(all).toContain(' ◷ 3m')
  expect(all).toContain(' ◷ ~30m')
  expect(all).toContain(' ◷ cold')
  expect(all.filter(t => t.includes('◷')).length).toBe(3)
})

test('a working card shows its action, never the word for its state', async ($, on) => {
  const projects = {
    projects: [{
      path: '/repo',
      sessions: [
        { id: 'A', agent: 'agy', activity: 'busy' },
        { id: 'B', agent: 'cursor', activity: 'busy', title: 'No action yet', state: 'working' },
      ],
    }],
  }
  engine(on, JSON.stringify(projects))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const lines = [...(await texts(ui)), ...(await ui.findAll({ type: 'Client' })).map(c => String((c.props.props as { text?: string }).text))]

  expect(lines.some(t => /\b(busy|working)\b/.test(t))).toBe(false)
  await ui.unmount()
})

test('a working card with nothing to tell yet still shows it works, never an empty line', async ($, on) => {
  engine(on, JSON.stringify({ projects: [{ path: '/repo', sessions: [{ id: 'A', agent: 'claude', activity: 'busy' }] }] }))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const shimmering = (await ui.findAll({ type: 'Client' })).map(c => (c.props.props as { text?: string }).text)

  expect(shimmering).toEqual(['…'])
  await ui.unmount()
})

test('a card is in its agent’s colour: the working line shimmers in that tone, as filetree’s do', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const shimmer = (await ui.findAll({ type: 'Client' }))
    .map(c => c.props.props as { text?: string; palette?: string[] })
    .find(p => p.text === 'Running the suite')

  expect(shimmer?.palette).toEqual(['#f97316', '#fb923c', '#fdba74', '#ffedd5'])
  const title = (await ui.findAll({ type: 'Text' })).find(t => t.text === 'Multi-provider')
  expect(title?.props.color).toBe('#f97316')
  await ui.unmount()
})

test('a model id reads as a person names it', () => {
  expect(modelLabel('Opus 5.5')).toBe('Opus 5.5')
  expect(modelLabel('claude-opus-5-5')).toBe('Opus 5.5')
  expect(modelLabel('claude-haiku-5-5-20261001')).toBe('Haiku 5.5')
  expect(modelLabel('claude-opus-4-20250514')).toBe('Opus 4')
  expect(modelLabel('claude-3-5-sonnet-20241022')).toBe('Sonnet 3.5')
  expect(modelLabel('gemini-3.8-flash-medium')).toBe('gemini-3.8 flash medium')
  expect(modelLabel('gpt-5.5-codex')).toBe('gpt-5.5 codex')
  expect(modelLabel('opencode/big-pickle')).toBe('opencode/big-pickle')
})

test('a session whose turn ended but whose subagents still run reads as working', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(PANE)
  const all = await texts(ui)
  const shimmering = (await ui.findAll({ type: 'Client' })).map(c => (c.props.props as { text?: string }).text)

  expect(shimmering).toContain('running 2 subagents')
  expect(all.indexOf('Fan out')).toBeLessThan(all.indexOf('Idle one'))
})

test('a file an older linkC wrote shows the agent and its activity, once', async ($, on) => {
  engine(on, JSON.stringify({ projects: [{ path: '/repo', sessions: [{ id: 'S1', agent: 'claude', activity: 'idle' }] }] }))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const all = await texts(await $.ui.mount(PANE))

  expect(all.filter(t => t.includes('claude'))).toEqual(['claude'])
  expect(all).toContain('idle')
})

test('an unreadable file says so instead of showing no sessions', async ($, on) => {
  engine(on, new Error('linkC is not running'))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const all = await texts(await $.ui.mount(PANE))

  expect(all.some(t => t.includes('cannot read') && t.includes('linkC is not running'))).toBe(true)
  expect(all).not.toContain(' No sessions in this repo.')
})

const BAND = {
  plugin: 'linkc-agents',
  component: 'AbovePrompt',
  surface: 'terminal',
  props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 6, bodyColumns: 120, scroll: { offset: 0, bodyRows: 6 }, view: {} },
} as const

/** The session's usage: 340k tokens of a 1M window, and 10% of the week spent. */
function usage(on: On, compactsAt = 1_000_000) {
  on('session.usage', () => ({
    value: {
      startedAt: 0,
      context: { tokens: 340_000, window: 1_000_000, percent: 34, breakdown: { rawMaxTokens: compactsAt } as Partial<SessionContextBreakdown> as SessionContextBreakdown },
      rateLimits: [{ kind: 'seven_day', percentUsed: 10, resetsAt: '2026-12-01T00:00:00Z' }],
    },
  }))
}

test('the band draws both meters in one box, their percents padded to line up', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  usage(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount(BAND)
  const all = await texts(ui)

  expect(all).toContain('context')
  expect(all).toContain('▰▰▰▱▱▱▱▱')
  expect(all).toContain(' 34%')
  expect(all).toContain('7d')
  expect(all).toContain('▰▱▱▱▱▱▱▱')
  expect(all).toContain(' 10%')
  expect((await ui.findAll({ type: 'Box' })).some(box => box.props.borderStyle === 'round')).toBe(true)
  await ui.unmount()
})

test('the context meter counts against the auto-compact point, as /context does', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  usage(on, 400_000)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  expect(await texts(await $.ui.mount(BAND))).toContain(' 85%')
})

test('Compact runs /compact, and hides while a turn runs', async ($, on) => {
  const clock = engine(on, JSON.stringify(PROJECTS))
  usage(on)
  const ran: string[] = []
  on('command.run', (_, e) => {
    ran.push(e.command)
    return { text: '' }
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const idle = await $.ui.mount(BAND)
  await idle.press({ key: 'compact' })
  await clock.advance(1)
  expect(ran).toEqual(['compact'])
  await idle.unmount()

  const working = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: true } })
  expect(await working.find({ type: 'Button', key: 'compact' })).toBeUndefined()
  await working.unmount()
})

test('with no usage yet the band draws nothing of its own', async ($, on) => {
  engine(on, JSON.stringify(PROJECTS))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 1_000_000 }, rateLimits: [] } }))
  on('ui.render', { component: 'AbovePrompt', plugin: '*' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>ENGINE</Text>
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

  const all = await texts(await $.ui.mount(BAND))
  expect(all.length > 0 && all.every(t => t === 'ENGINE')).toBe(true)
})
