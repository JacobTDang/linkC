import type { ClientModule } from 'claude-code'

/** A line of text with a band of light sweeping along it, the way filetree marks what is at work. */
export type ShimmerProps = { text: string; palette: string[] }

const TICK_MS = 90

/**
 * The colour of character `i` of `len` at `phase`: the band moves 1.6 cells a tick and wraps with
 * four cells of rest either side; `palette` runs from the line's own colour to the band's brightest.
 */
export function shimmerColor(i: number, phase: number, len: number, palette: string[]): string {
  const band = ((phase * 1.6) % (len + 8)) - 4
  const distance = Math.abs(i - band)
  const level = distance < 0.8 ? 3 : distance < 1.8 ? 2 : distance < 2.8 ? 1 : 0
  return palette[level] ?? palette[0] ?? ''
}

const Shimmer: ClientModule<ShimmerProps, { phase: number; isTicking?: true }> = (props, surface) => {
  const { Text } = surface.elements
  let state = surface.state
  if (state === undefined) {
    state = { phase: 0 }
    surface.setState(state)
  }
  // One timer for the module's life; the surface ends it when the line goes.
  if (!state.isTicking) {
    surface.every(TICK_MS, () => {
      const now = surface.state
      if (now) surface.setState({ ...now, phase: now.phase + 1 })
    })
    surface.setState({ ...state, isTicking: true })
  }
  const chars = [...props.text]
  return (
    <Text wrap="truncate-end">
      {chars.map((char, i) => (
        <Text color={shimmerColor(i, state.phase, chars.length, props.palette)}>{char}</Text>
      ))}
    </Text>
  )
}

export default Shimmer
