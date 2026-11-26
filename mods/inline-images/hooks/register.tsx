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
// A picture with a longer side is converted even when it is a small PNG: the
// terminal refuses one over 10000 px, and decoding a huge one costs memory.
const LARGEST = 1600
const SIDES = [LARGEST, 1200, 900, 600]
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

// What a row draws for one picture: the picture, the line saying it is being
// converted, or why it cannot be shown.
type Look = { picture: Picture } | { isConverting: true } | { error: string }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

const messageOf = (failure: unknown) =>
  failure instanceof Error ? failure.message : String(failure)

function wanted(call: Call): Wanted[] {
  const { output } = call
  if (!PICTURE_TOOLS.has(call.tool) || call.isRunning || call.isErrored || !isRecord(output)) {
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

// Width and height from a PNG's IHDR chunk, which every PNG starts with, or
// undefined when the bytes are not a PNG.
function pngSize(png: string): { width: number; height: number } | undefined {
  const head = atob(png.slice(0, 32))
  const word = (at: number) =>
    ((head.charCodeAt(at) << 24) |
      (head.charCodeAt(at + 1) << 16) |
      (head.charCodeAt(at + 2) << 8) |
      head.charCodeAt(at + 3)) >>>
    0
  if (head.length < 24 || !head.startsWith('\x89PNG\r\n\x1a\n')) {
    return undefined
  }

  return { width: word(16), height: word(20) }
}

// The PNG as it is, when the terminal can draw it without converting it.
function drawable(png: string): Picture | undefined {
  const size = pngSize(png)
  if (size === undefined || Math.max(size.width, size.height) > LARGEST) {
    return undefined
  }

  return { png, ...size }
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

async function readBytes($: EngineInterface, path: string): Promise<string> {
  return ((await $.fs.read(path, { as: 'bytes' })) as { base64: string }).base64
}

// Where the converted copy of one version of a picture is kept. Every version
// of the same picture starts with the same hash of its path.
async function cachePath($: EngineInterface, path: string, stat: { size: number; mtimeMs: number }) {
  const folder = `${(await $.process.hookEnv()).CLAUDE_PLUGIN_DATA}/png`
  const name = path.split('/').pop()?.replace(/\.[^.]*$/, '') || 'picture'
  const version = fnv1a(`${stat.size}|${stat.mtimeMs}`)

  return { folder, out: `${folder}/${fnv1a(path)}-${version}-${name}.png` }
}

// Turns any picture sips reads (JPEG, HEIC, WebP, GIF, big PNGs) into a PNG
// under 2 MiB at `out`. sips writes beside it, and only a whole PNG that fits
// is moved into place, so a cut-short run never leaves a broken one there.
// Earlier versions of the same picture are then removed.
async function convert($: EngineInterface, path: string, folder: string, out: string) {
  await run($, ['mkdir', '-p', folder], folder)
  const side = await pixelSize($, path)
  const tries = side > LARGEST ? SIDES : [undefined, ...SIDES.filter(most => most < side)]
  const temp = `${folder}/.${Math.random().toString(36).slice(2)}.png`
  try {
    for (const most of tries) {
      const fit = most === undefined ? [] : ['-Z', String(most)]
      await run($, ['sips', '-s', 'format', 'png', ...fit, path, '--out', temp], path)
      if ((await $.fs.stat(temp)).size <= PNG_LIMIT) {
        await run($, ['mv', '-f', temp, out], out)
        await prune($, folder, out)

        return
      }
    }
  } finally {
    await run($, ['rm', '-f', temp], temp)
  }
  throw new Error(`${path} is still over 2 MB as a PNG at ${tries.at(-1) ?? side} px`)
}

async function prune($: EngineInterface, folder: string, out: string) {
  const kept = out.slice(folder.length + 1)
  const picture = `${kept.split('-')[0]}-`
  const stale = (await $.fs.list(folder))
    .filter(entry => entry.name.startsWith(picture) && entry.name !== kept)
    .map(entry => `${folder}/${entry.name}`)
  if (stale.length > 0) {
    await run($, ['rm', '-f', ...stale], folder)
  }
}

// Conversions since this load, by cache path: running, or failed and why. A
// finished one is in the cache folder, and nothing of it is held here.
const conversions = new Map<string, { error?: string }>()

// Converts after the drawing has answered, so the row never waits on sips,
// then has the rows drawn again.
function startConverting($: EngineInterface, path: string, folder: string, out: string) {
  conversions.set(out, {})
  $.clock.after(0, () => {
    convert($, path, folder, out)
      .then(
        () => conversions.delete(out),
        failure => conversions.set(out, { error: messageOf(failure) }),
      )
      .finally(() => $.ui.invalidate('ui.render'))
  })
}

async function look($: EngineInterface, want: Wanted): Promise<Look> {
  const given = want.png === undefined ? undefined : drawable(want.png)
  if (given) {
    return { picture: given }
  }
  const stat = await $.fs.stat(want.path)
  if (/\.png$/i.test(want.path) && stat.size <= PNG_LIMIT) {
    const asItIs = drawable(await readBytes($, want.path))
    if (asItIs) {
      return { picture: asItIs }
    }
  }
  const { folder, out } = await cachePath($, want.path, stat)
  const conversion = conversions.get(out)
  if (conversion?.error !== undefined) {
    return { error: conversion.error }
  }
  if (conversion) {
    return { isConverting: true }
  }
  if (await $.fs.exists(out)) {
    if ((await $.fs.stat(out)).size <= PNG_LIMIT) {
      const png = await readBytes($, out)
      const size = pngSize(png)
      if (size === undefined) {
        throw new Error(`the cached copy ${out} is not a PNG`)
      }

      return { picture: { png, ...size } }
    }
    await run($, ['rm', '-f', out], out)
  }
  startConverting($, want.path, folder, out)

  return { isConverting: true }
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
    if (e.surface !== 'terminal') {
      return next(e)
    }
    const list = wanted(e.props)
    if (list.length === 0 || !(await read($, isOn))) {
      return next(e)
    }
    const row = await next(e)
    const looks = await Promise.all(
      list.map(want =>
        look($, want).then(
          (one): Look & { path: string } => ({ ...one, path: want.path }),
          failure => ({ path: want.path, error: messageOf(failure) }),
        ),
      ),
    )
    const { Box, Image, Text } = $.ui.resolve(e)
    const room = e.viewport?.columns ?? 80

    return (
      <Box flexDirection="column">
        {row}
        {looks.map(one =>
          'picture' in one ? (
            <Box paddingLeft={2}>
              <Image
                source={{ png: one.picture.png }}
                {...box(one.picture, room)}
                alt={`[image] ${one.path} (this terminal can't draw pictures)`}
              />
            </Box>
          ) : 'error' in one ? (
            <Text color="error">
              {'  '}inline-images: {one.error}
            </Text>
          ) : (
            <Text dimColor>
              {'  '}[image] {one.path} (converting to draw it here)
            </Text>
          ),
        )}
      </Box>
    )
  })
}
