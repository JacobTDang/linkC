import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Picture } from '../types'

const isOn = atom({ plugin: 'inline-images', key: 'isOn' } as const, true)

// Tools whose rows can carry a picture: a Read of an image file, and the
// messages and files Claude sends to the person.
const PICTURE_TOOLS = new Set(['Read', 'SendUserMessage', 'SendUserFile'])

// An Image takes at most 2 MiB of PNG bytes.
const PNG_LIMIT = 2 * 1024 * 1024
// Longest side of a converted picture, then smaller tries while it is too big.
const SIDES = [1600, 1200, 900, 600]
// A terminal cell is about 2.1 times taller than wide, and about 8 px across.
const CELL_ASPECT = 2.1
const PIXELS_PER_COLUMN = 8
const MAX_COLUMNS = 120
const MAX_ROWS = 40

type Call = {
  tool: string
  input: unknown
  output?: unknown
  isRunning: boolean
  isErrored: boolean
}

// What a finished call shows: the file's path, and the PNG bytes when the
// result already holds them.
type Wanted = { path: string; png?: string }

type Shown = { path: string; picture: Picture } | { path: string; error: string }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

function wanted(call: Call): Wanted[] {
  const { output } = call
  if (call.isRunning || call.isErrored || !isRecord(output)) {
    return []
  }
  if (call.tool === 'Read') {
    const path = isRecord(call.input) ? call.input.file_path : undefined
    if (output.type !== 'image' || typeof path !== 'string') {
      return []
    }
    const file = isRecord(output.file) ? output.file : {}
    const isSmallPng =
      file.type === 'image/png' &&
      typeof file.base64 === 'string' &&
      (file.base64.length * 3) / 4 <= PNG_LIMIT

    return [{ path, png: isSmallPng ? (file.base64 as string) : undefined }]
  }
  const attachments = Array.isArray(output.attachments) ? output.attachments : []

  return attachments
    .filter(isRecord)
    .filter(one => one.isImage === true && typeof one.path === 'string')
    .map(one => ({ path: one.path as string }))
}

// Width and height from a PNG's IHDR chunk, which every PNG starts with.
function pngSize(png: string): { width: number; height: number } {
  const head = atob(png.slice(0, 32))
  const word = (at: number) =>
    ((head.charCodeAt(at) << 24) |
      (head.charCodeAt(at + 1) << 16) |
      (head.charCodeAt(at + 2) << 8) |
      head.charCodeAt(at + 3)) >>>
    0
  if (head.length < 24 || !head.startsWith('\x89PNG')) {
    throw new Error('the picture is not a PNG')
  }

  return { width: word(16), height: word(20) }
}

function fnv1a(text: string): string {
  let hash = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }

  return (hash >>> 0).toString(16).padStart(8, '0')
}

async function run($: EngineInterface, argv: string[], about: string): Promise<string> {
  const ran = await $.process.run(argv, { timeoutMs: 20_000 })
  if (ran.exitCode !== 0) {
    const why = ran.stderr.trim() || ran.stdout.trim() || `exit ${ran.exitCode}`
    throw new Error(`${argv[0]} failed on ${about}: ${why}`)
  }

  return ran.stdout
}

async function pixelSize($: EngineInterface, path: string): Promise<number> {
  const out = await run($, ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path], path)
  const width = Number(/pixelWidth:\s*(\d+)/.exec(out)?.[1])
  const height = Number(/pixelHeight:\s*(\d+)/.exec(out)?.[1])
  if (!width || !height) {
    throw new Error(`sips could not read the size of ${path}`)
  }

  return Math.max(width, height)
}

async function readPng($: EngineInterface, path: string): Promise<Picture> {
  const { base64 } = (await $.fs.read(path, { as: 'bytes' })) as { base64: string }

  return { png: base64, ...pngSize(base64) }
}

// Turns any picture sips reads (JPEG, HEIC, WebP, GIF, big PNGs) into a PNG
// under 2 MiB in the mod's data folder, kept there for the next draw.
async function convert($: EngineInterface, path: string, id: string): Promise<Picture> {
  const folder = `${(await $.process.hookEnv()).CLAUDE_PLUGIN_DATA}/png`
  const name = path.split('/').pop()?.replace(/\.[^.]*$/, '') ?? 'picture'
  const out = `${folder}/${fnv1a(id)}-${name}.png`
  if (await $.fs.exists(out)) {
    return readPng($, out)
  }
  await run($, ['mkdir', '-p', folder], folder)
  const side = await pixelSize($, path)
  for (const most of SIDES) {
    const fit = side > most ? ['-Z', String(most)] : []
    await run($, ['sips', '-s', 'format', 'png', ...fit, path, '--out', out], path)
    if ((await $.fs.stat(out)).size <= PNG_LIMIT) {
      return readPng($, out)
    }
  }
  await run($, ['rm', '-f', out], out)
  throw new Error(`${path} is still over 2 MB as a PNG at ${SIDES.at(-1)} px`)
}

// Conversions in flight or done since this load, by path, size and time.
const pictures = new Map<string, Promise<Picture>>()

async function pictureOf($: EngineInterface, want: Wanted): Promise<Picture> {
  if (want.png !== undefined) {
    return { png: want.png, ...pngSize(want.png) }
  }
  const stat = await $.fs.stat(want.path)
  const isSmallPng = /\.png$/i.test(want.path) && stat.size <= PNG_LIMIT
  if (isSmallPng) {
    return readPng($, want.path)
  }
  const id = `${want.path}|${stat.size}|${stat.mtimeMs}`
  const known = pictures.get(id)
  if (known) {
    return known
  }
  const made = convert($, want.path, id)
  pictures.set(id, made)
  made.catch(() => pictures.delete(id))

  return made
}

// The box of cells the picture fills: as wide as the room allows, never
// past about one cell per 8 px, and no taller than MAX_ROWS.
function box(picture: Picture, room: number): { columns: number; rows: number } {
  const ratio = picture.height / picture.width
  let columns = Math.min(
    MAX_COLUMNS,
    Math.max(10, room - 6),
    Math.ceil(picture.width / PIXELS_PER_COLUMN),
  )
  let rows = Math.max(1, Math.round((columns * ratio) / CELL_ASPECT))
  if (rows > MAX_ROWS) {
    rows = MAX_ROWS
    columns = Math.max(1, Math.round((rows * CELL_ASPECT) / ratio))
  }

  return { columns: Math.min(255, columns), rows: Math.min(255, rows) }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'images',
      description: 'Pictures inline in the chat: /images on, /images off, /images switches',
      argumentHint: '[on|off]',
    })
    const stored = await $.store.get('isOn')
    if (typeof stored === 'boolean') {
      await update($, isOn, () => stored)
    }

    return next(e)
  })

  on('command.run', { command: 'images' }, async ($, e) => {
    const word = e.args.trim().toLowerCase()
    if (word !== '' && word !== 'on' && word !== 'off') {
      return { text: 'Usage: /images [on|off]' }
    }
    const now = word === '' ? !(await read($, isOn)) : word === 'on'
    await update($, isOn, () => now)
    await $.store.set('isOn', now)

    return {
      text: now
        ? 'Inline images on: pictures show under the rows that read or send them.'
        : 'Inline images off.',
    }
  })

  // Reads are folded into one count line; unfold a group holding a picture so
  // each read is its own row, which the ToolUse hook below draws under.
  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    const hasPicture = e.props.calls.some(call => wanted(call).length > 0)
    if (e.surface !== 'terminal' || e.props.isExpanded || !hasPicture) {
      return next(e)
    }
    if (!(await read($, isOn))) {
      return next(e)
    }

    return next({ ...e, props: { ...e.props, isExpanded: true } })
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || !PICTURE_TOOLS.has(e.props.tool)) {
      return next(e)
    }
    const list = wanted(e.props)
    if (list.length === 0 || !(await read($, isOn))) {
      return next(e)
    }
    const row = await next(e)
    const shown: Shown[] = await Promise.all(
      list.map(async want => {
        try {
          return { path: want.path, picture: await pictureOf($, want) }
        } catch (failure) {
          const error = failure instanceof Error ? failure.message : String(failure)

          return { path: want.path, error }
        }
      }),
    )
    const { Box, Image, Text } = $.ui.resolve(e)
    const room = e.viewport?.columns ?? 80

    return (
      <Box flexDirection="column">
        {row}
        {shown.map(one =>
          'picture' in one ? (
            <Box paddingLeft={2}>
              <Image
                source={{ png: one.picture.png }}
                {...box(one.picture, room)}
                alt={`[image] ${one.path} (this terminal can't draw pictures)`}
              />
            </Box>
          ) : (
            <Text color="error">
              {'  '}inline-images: {one.error}
            </Text>
          ),
        )}
      </Box>
    )
  })
}
