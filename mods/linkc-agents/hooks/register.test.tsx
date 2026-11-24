import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

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
        { id: 'ME', agent: 'claude', activity: 'busy', title: 'Multi-provider', state: 'working', since: minutesAgo(4), action: 'Running the suite' },
      ],
    },
    {
      path: '/repo/.worktrees/fix',
      sessions: [
        { id: 'ASK', agent: 'agy', activity: 'busy', title: 'Fix default', state: 'waitingPermission', since: minutesAgo(1), worker: true },
      ],
    },
    { path: '/other', sessions: [{ id: 'ELSE', agent: 'cursor', activity: 'busy', title: 'Elsewhere', state: 'working' }] },
  ],
}

/** The engine around the mod: home, this session's id, its folder in /repo, and linkC's file. */
function engine(on: On, file: string | Error, seen: { bodyRows?: number } = {}) {
  on('env.get', (_, e) => ({ value: { HOME, LINKC_SESSION: 'ME' }[e.name] }))
  on('session.cwd', () => ({ value: '/repo/Sources' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '/repo/.git\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('fs.read', (_, e) => {
    if (e.path !== FILE) return { deny: `unexpected read of ${e.path}` }
    if (file instanceof Error) return { deny: file.message }
    return { value: file }
  })
  on('clock.every', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  // filetree's own drawing, beneath the mod.
  on('ui.render', { component: 'Pane', plugin: '*' }, ($, e) => {
    seen.bodyRows = e.props.scroll?.bodyRows
    const { Text } = $.ui.resolve(e)
    return <Text>TREE</Text>
  })
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

  const all = await texts(await $.ui.mount(PANE))

  expect(all).toContain('Running the suite')
  expect(all).toContain('needs permission fix')
  expect(all).toContain(' agy · worker')
  expect(all).toContain(' · you')
  expect(all).toContain(' 4m ')
  expect(all).toContain(' 12m ')
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
