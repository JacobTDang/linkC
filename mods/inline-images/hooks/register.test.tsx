import { expect, test } from 'claude-code/testing'

// A real 200 by 100 PNG, so the size is read from its own header.
const PNG_200x100 =
  'iVBORw0KGgoAAAANSUhEUgAAAMgAAABkCAIAAABM5OhcAAABG0lEQVR4nO3SQQkAIADAQOMYx9jGsoRDkIMLsMfGXhOuG88L+JKxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLhLFIGIuEsUgYi4SxSBiLxAHkea2w4itvtgAAAABJRU5ErkJggg=='

// Neither output stream was cut short.
const WHOLE = { isStdoutTruncated: false, isStderrTruncated: false }

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

const messageWithJpeg = {
  ...CALL,
  tool: 'SendUserMessage',
  input: { message: 'Round D' },
  output: {
    message: 'Round D',
    attachments: [
      { path: 'shots/contact-sheet.jpg', size: 265900, isImage: true },
    ],
  },
}

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

test('a JPEG a message sends is turned into a PNG by sips', async ($, on) => {
  const runs: string[][] = []
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('process.run', (_, e) => {
    runs.push([...e.argv])
    const stdout = e.argv.includes('-g')
      ? `${e.argv.at(-1)}\n  pixelWidth: 3200\n  pixelHeight: 1600\n`
      : ''

    return { value: { exitCode: 0, stdout, stderr: '', ...WHOLE } }
  })
  on('fs.stat', () => ({
    value: { kind: 'file', size: 265900, mtimeMs: 5, isLink: false },
  }))
  on('fs.exists', () => ({ value: false }))
  on('fs.read', () => ({ value: { base64: PNG_200x100 } }))

  const ui = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })

  expect((await ui.find({ type: 'Image' }))?.props.source).toEqual({
    png: PNG_200x100,
  })
  const convert = runs.find(argv => argv.includes('format'))
  expect(convert?.slice(0, 6)).toEqual(['sips', '-s', 'format', 'png', '-Z', '1600'])
  expect(convert?.[6]).toBe('shots/contact-sheet.jpg')
  expect(convert?.[8]).toMatch(/^\/data\/png\/.+\.png$/)
  await ui.unmount()
})

test('a picture sips cannot convert says why under the row', async ($, on) => {
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('process.run', (_, e) => ({
    value: e.argv.includes('-g')
      ? { exitCode: 0, stdout: '  pixelWidth: 10\n  pixelHeight: 10\n', stderr: '', ...WHOLE }
      : { exitCode: 13, stdout: '', stderr: 'Error: unsupported format\n', ...WHOLE },
  }))
  on('fs.stat', () => ({
    value: { kind: 'file', size: 100, mtimeMs: 1, isLink: false },
  }))
  on('fs.exists', () => ({ value: false }))

  const ui = await $.ui.mount({ ...row(messageWithJpeg), surface: 'terminal' })

  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  const error = await ui.find({ type: 'Text', text: /unsupported format/ })
  expect(error?.props.color).toBe('error')
  await ui.unmount()
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

test('a folded group holding an image read unfolds, so its row shows', async ($, on) => {
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
  expect(await withImage.find({ type: 'Text', text: 'unfolded' })).toBeDefined()
  await withImage.unmount()

  const textOnly = await group([
    { ...CALL, tool: 'Read', input: { file_path: 'a.md' }, output: { type: 'text' } },
  ])
  expect(await textOnly.find({ type: 'Text', text: 'folded' })).toBeDefined()
  await textOnly.unmount()
})
