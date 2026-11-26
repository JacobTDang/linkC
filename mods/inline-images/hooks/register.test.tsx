import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// A real 200 by 100 PNG, so the size is read from its own header.
const PNG_200x100 =
  'iVBORw0KGgoAAAANSUhEUgAAAMgAAABkCAIAAABM5OhcAAABG0lEQVR4nO3SQQkAIADAQOMYx9jGsoRDkIMLsMfGXhOuG88L+JKxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLxAHkea2w4itvtgAAAABJRU5ErkJggg=='

// The start of a JPEG: what a tool that saved JPEG bytes as .png leaves.
const JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDA=='

// The first bytes of a PNG of any size: the signature and its IHDR chunk.
function pngHead(width: number, height: number): string {
  const word = (n: number) => [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]
  const bytes = [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...word(13), 0x49, 0x48, 0x44, 0x52, ...word(width), ...word(height),
    8, 6, 0, 0, 0,
  ]

  return btoa(String.fromCharCode(...bytes))
}

// Neither output stream was cut short.
const WHOLE = { isStdoutTruncated: false, isStderrTruncated: false }

const MB = 1024 * 1024

type File = { size: number; mtimeMs: number }

type Disk = {
  files: Map<string, File>
  runs: string[][]
  // The sips runs that made a PNG.
  conversions: () => string[][]
  // What the mod keeps in its data folder.
  cache: () => string[]
}

// A disk the mocks share: sips writes PNGs of `pngSize` bytes for the longest
// side it was given (undefined for the picture's own), `mv` moves, `rm` drops,
// and `fails` makes a sips conversion exit 13 with that line.
function disk(
  on: On,
  options: {
    files: Record<string, number>
    pixels: number
    pngSize?: (side: number | undefined) => number
    reads?: Record<string, string>
    fails?: (side: number | undefined) => string | undefined
  },
): Disk {
  const files = new Map(
    Object.entries(options.files).map(([path, size]) => [path, { size, mtimeMs: 5 }]),
  )
  const runs: string[][] = []
  const pngSize = options.pngSize ?? (() => 300_000)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('process.run', (_, e) => {
    const argv = [...e.argv]
    runs.push(argv)
    const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '', ...WHOLE } })
    if (argv[0] === 'sips' && argv.includes('-g')) {
      return ok(`${argv.at(-1)}\n  pixelWidth: ${options.pixels}\n  pixelHeight: 50\n`)
    }
    if (argv[0] === 'sips') {
      const z = argv.indexOf('-Z')
      const side = z < 0 ? undefined : Number(argv[z + 1])
      const why = options.fails?.(side)
      if (why !== undefined) {
        return { value: { exitCode: 13, stdout: '', stderr: `${why}\n`, ...WHOLE } }
      }
      files.set(argv.at(-1) as string, { size: pngSize(side), mtimeMs: 1 })

      return ok()
    }
    if (argv[0] === 'mv') {
      const [from, to] = argv.slice(-2) as [string, string]
      files.set(to, files.get(from) as File)
      files.delete(from)
    }
    if (argv[0] === 'rm') {
      for (const path of argv.slice(2)) files.delete(path)
    }

    return ok()
  })
  on('fs.exists', (_, e) => ({ value: files.has(e.path) }))
  on('fs.stat', (_, e) => {
    const file = files.get(e.path)

    return file
      ? { value: { kind: 'file', ...file, isLink: false } }
      : { deny: `ENOENT: ${e.path}` }
  })
  on('fs.list', (_, e) => ({
    value: [...files.entries()]
      .filter(([path]) => path.startsWith(`${e.path}/`))
      .map(([path, file]) => ({
        name: path.slice(e.path.length + 1),
        kind: 'file' as const,
        ...file,
        isLink: false,
      })),
  }))
  on('fs.read', (_, e) => ({ value: { base64: options.reads?.[e.path] ?? PNG_200x100 } }))

  return {
    files,
    runs,
    conversions: () => runs.filter(argv => argv[0] === 'sips' && argv.includes('format')),
    cache: () => [...files.keys()].filter(path => path.startsWith('/data/png/')),
  }
}

const CALL = {
  tool_use_id: 'toolu_1',
  isRunning: false,
  isErrored: false,
  isInterrupted: false,
}

const readOfPng = {
  ...CALL,
  tool: 'Read',
  input: { file_path: '/shots/wide.png' },
  output: {
    type: 'image',
    file: { base64: PNG_200x100, type: 'image/png', originalSize: 456 },
  },
}

const sent = (path: string, size: number) => ({
  ...CALL,
  tool: 'SendUserMessage',
  input: { message: 'Round D' },
  output: { message: 'Round D', attachments: [{ path, size, isImage: true }] },
})

const messageWithJpeg = sent('/shots/contact-sheet.jpg', 265_900)

const row = (props: typeof readOfPng | typeof messageWithJpeg) => ({
  plugin: 'inline-images',
  component: 'ToolUse' as const,
  requestId: 'toolu_1',
  viewport: { columns: 100, rows: 40 },
  props,
})

test('a Read of a PNG draws the picture under its row', async $ => {
  const ui = await $.ui.mount({ ...row(readOfPng), surface: 'terminal' })

  const image = await ui.find({ type: 'Image' })
  // 200 px at 8 px a column is 25 columns; 100 px tall at 2.1 is 6 rows.
  expect(image?.props).toMatchObject({
    source: { png: PNG_200x100 },
    columns: 25,
    rows: 6,
  })
  expect(await ui.drawn()).toMatchObject({
    type: 'Box',
    children: [{ type: 'engine' }, expect.anything()],
  })
  await ui.unmount()
})

test('a JPEG a message sends shows its row at once, then the PNG sips made', async ($, on) => {
  const clock = mock.clock(on)
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 3200,
  })

  const ui = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })

  // The row does not wait for sips: it shows with a line saying so.
  expect(await ui.drawn()).toMatchObject({
    type: 'Box',
    children: [{ type: 'engine' }, expect.anything()],
  })
  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /converting/ })).toBeDefined()

  await clock.settle()

  expect((await ui.find({ type: 'Image' }))?.props.source).toEqual({ png: PNG_200x100 })
  const convert = world.conversions()[0] ?? []
  expect(convert.slice(0, 7)).toEqual([
    'sips', '-s', 'format', 'png', '-Z', '1600', '/shots/contact-sheet.jpg',
  ])
  // sips writes beside the cache file, which only a whole PNG that fits replaces.
  const kept = world.cache()[0]
  expect(world.cache()).toHaveLength(1)
  expect(kept).toMatch(/^\/data\/png\/[^/]+\.png$/)
  expect(convert.at(-1)).not.toBe(kept)
  expect(world.runs).toContainEqual(['mv', '-f', convert.at(-1), kept])
  await ui.unmount()
})

test('a converted picture is drawn from the cache without running sips again', async ($, on) => {
  const clock = mock.clock(on)
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 3200,
  })

  const first = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()
  await first.unmount()
  const again = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })

  expect(await again.find({ type: 'Image' })).toBeDefined()
  expect(world.conversions()).toHaveLength(1)
  await again.unmount()
})

test('a cached PNG over the size limit is made again', async ($, on) => {
  const clock = mock.clock(on)
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 3200,
  })
  const first = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()
  await first.unmount()
  const kept = world.cache()[0] ?? ''
  world.files.set(kept, { size: 3 * MB, mtimeMs: 1 })

  const again = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()

  expect(world.conversions()).toHaveLength(2)
  expect(world.files.get(kept)?.size).toBe(300_000)
  expect(await again.find({ type: 'Image' })).toBeDefined()
  await again.unmount()
})

test('a conversion cut short leaves nothing in the cache', async ($, on) => {
  const clock = mock.clock(on)
  // At 1600 px the PNG is too big; the 1200 px run times out.
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 3200,
    pngSize: () => 3 * MB,
    fails: side => (side === 1200 ? 'timed out' : undefined),
  })

  const ui = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()

  expect(world.cache()).toEqual([])
  expect(await ui.find({ type: 'Text', text: /timed out/ })).toBeDefined()
  await ui.unmount()
})

test('a picture sips cannot convert says why under the row', async ($, on) => {
  const clock = mock.clock(on)
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 10,
    fails: () => 'Error: unsupported format',
  })

  const ui = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()

  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  const error = await ui.find({
    type: 'Text',
    text: /inline-images: sips failed on \/shots\/contact-sheet\.jpg: Error: unsupported format/,
  })
  expect(error?.props.color).toBe('error')
  expect(world.cache()).toEqual([])
  await ui.unmount()
})

test('a small PNG taller than 1600 px is scaled down before it is drawn', async ($, on) => {
  const clock = mock.clock(on)
  // A full-page screenshot: 1.5 MB, but 12000 px tall.
  const world = disk(on, {
    files: { '/shots/page.png': 1.5 * MB },
    pixels: 12_000,
    reads: { '/shots/page.png': pngHead(1280, 12_000) },
  })

  const ui = await $.ui.mount({ ...row(sent('/shots/page.png', 1.5 * MB)), surface: 'terminal' })
  await clock.settle()

  const convert = world.conversions()[0] ?? []
  expect(convert.slice(4, 7)).toEqual(['-Z', '1600', '/shots/page.png'])
  expect((await ui.find({ type: 'Image' }))?.props.source).toEqual({ png: PNG_200x100 })
  await ui.unmount()
})

test('a .png holding JPEG bytes is converted, not refused', async ($, on) => {
  const clock = mock.clock(on)
  const world = disk(on, {
    files: { '/shots/hero.png': 300_000 },
    pixels: 800,
    reads: { '/shots/hero.png': JPEG },
  })

  const ui = await $.ui.mount({ ...row(sent('/shots/hero.png', 300_000)), surface: 'terminal' })
  await clock.settle()

  expect(world.conversions()).toHaveLength(1)
  expect(await ui.find({ type: 'Image' })).toBeDefined()
  await ui.unmount()
})

test('a picture already small enough is converted at full size only once', async ($, on) => {
  const clock = mock.clock(on)
  // 1000 px across: 2.5 MB as a PNG at full size, 1 MB at 900 px.
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 1000,
    pngSize: side => (side === undefined ? 2.5 * MB : 1 * MB),
  })

  const ui = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()

  const sides = world.conversions().map(argv => (argv[4] === '-Z' ? argv[5] : 'full'))
  expect(sides).toEqual(['full', '900'])
  await ui.unmount()
})

test('a new version of a picture replaces the old one in the cache', async ($, on) => {
  const clock = mock.clock(on)
  const world = disk(on, {
    files: { '/shots/contact-sheet.jpg': 265_900 },
    pixels: 3200,
  })
  const first = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()
  await first.unmount()
  const [old] = world.cache()

  world.files.set('/shots/contact-sheet.jpg', { size: 270_000, mtimeMs: 9 })
  const again = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })
  await clock.settle()

  expect(world.conversions()).toHaveLength(2)
  expect(world.cache()).toHaveLength(1)
  expect(world.cache()).not.toContain(old)
  await again.unmount()
})

test('/images off hides the pictures and is remembered', async ($, on) => {
  const stored: unknown[] = []
  on('command.register', () => ({ value: { command: 'images' } }))
  on('store.get', () => ({ value: undefined }))
  on('store.set', (_, e) => {
    stored.push(e)

    return { value: undefined }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const answer = await $.command.run({
    command: 'images',
    args: 'off',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 100 },
  })

  expect(answer).toMatchObject({ text: expect.stringMatching(/off/) })
  expect(stored).toContainEqual({ key: 'isOn', value: false })
  const ui = await $.ui.mount({ ...row(readOfPng), surface: 'terminal' })
  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  await ui.unmount()
})

test('a stored "off" holds in a new session', async ($, on) => {
  on('command.register', () => ({ value: { command: 'images' } }))
  on('store.get', () => ({ value: false }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...row(readOfPng), surface: 'terminal' })
  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  await ui.unmount()
})

test('surfaces without pictures draw the row as it was', async $ => {
  for (const surface of ['desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...row(readOfPng), surface })

    expect(await ui.drawn()).toMatchObject({ type: 'engine' })
    await ui.unmount()
  }
})

test('a folded group unfolds only for a row that draws a picture', async ($, on) => {
  on('ui.render', { component: 'ToolGroup' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>{e.props.isExpanded ? 'unfolded' : 'folded'}</Text>
  })

  const group = (calls: unknown[]) =>
    $.ui.mount({
      plugin: 'inline-images',
      surface: 'terminal',
      component: 'ToolGroup',
      props: { calls: calls as never, isActive: false, isExpanded: false },
    })

  const withImage = await group([readOfPng])
  expect(await withImage.find({ type: 'Text', text: /^unfolded$/ })).toBeDefined()
  await withImage.unmount()

  const textOnly = await group([
    { ...CALL, tool: 'Read', input: { file_path: 'a.md' }, output: { type: 'text' } },
  ])
  expect(await textOnly.find({ type: 'Text', text: /^folded$/ })).toBeDefined()
  await textOnly.unmount()

  // Another tool's result with image attachments: no row of this mod draws it.
  const otherTool = await group([
    { ...sent('/shots/a.png', 100), tool: 'mcp__lab__snap' },
  ])
  expect(await otherTool.find({ type: 'Text', text: /^folded$/ })).toBeDefined()
  await otherTool.unmount()
})
