/** A picture ready to draw: whole PNG bytes, base64, and its size in pixels. */
export type Picture = { png: string; width: number; height: number }

declare module 'claude-code' {
  interface PluginState {
    'inline-images': { isOn: boolean }
  }
}
