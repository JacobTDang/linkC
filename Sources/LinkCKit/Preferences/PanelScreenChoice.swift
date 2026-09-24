public enum PanelScreenChoice {
    /// A panel move, read: `save` is the display to remember, set only when the panel left the
    /// display linkC placed it on while that display is still connected (a user drag, not macOS
    /// evacuating an unplugged monitor); `placed` is where the panel now is, tracked either way.
    public static func afterMove(to current: UInt32?, placed: UInt32?, connected: [UInt32]) -> (save: UInt32?, placed: UInt32?) {
        guard let current else { return (nil, placed) }
        guard let placed, current != placed, connected.contains(placed) else { return (nil, current) }
        return (current, current)
    }

    /// The display the panel opens on: the one it was last on, if still connected; else the one
    /// under the mouse; else the one showing the menu-bar icon; else the first display.
    public static func pick(
        remembered: UInt32?,
        connected: [UInt32],
        underMouse: UInt32?,
        statusItem: UInt32?
    ) -> UInt32? {
        for candidate in [remembered, underMouse, statusItem] {
            if let candidate, connected.contains(candidate) {
                return candidate
            }
        }
        return connected.first
    }
}
