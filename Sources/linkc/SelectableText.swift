import SwiftUI
import LinkCKit

/// Dragging the panel's body moves it — that is how it gets positioned, and it should stay
/// that way. But AppKit decides "can this drag move the window" per NSView, and SwiftUI
/// collapses the entire panel into ONE hosting view: probing it shows plain text, selectable
/// text and tappable rows all hit the same view and all report `mouseDownCanMoveWindow`.
/// There is no region to carve the drag out of, and `.textSelection(.enabled)` on its own
/// changes nothing — the window still slides out from under the selection.
///
/// So the single lever gets toggled instead: while the pointer is over text worth copying,
/// the panel stops being draggable and a drag selects. Everywhere else, drag-to-move is
/// exactly as it was.
private struct WindowDraggableKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var setWindowDraggable: @MainActor @Sendable (Bool) -> Void {
        get { self[WindowDraggableKey.self] }
        set { self[WindowDraggableKey.self] = newValue }
    }
}

private struct SelectableTextModifier: ViewModifier {
    @Environment(\.setWindowDraggable) private var setWindowDraggable

    func body(content: Content) -> some View {
        content
            .textSelection(.enabled)
            .onHover { setWindowDraggable(!$0) }
            // A hovered view can be torn down before the exit event arrives — a row drops
            // out of a list, a screen swaps — and the panel would stay undraggable for the
            // rest of the session. Restore on the way out.
            .onDisappear { setWindowDraggable(true) }
    }
}

extension View {
    /// Text the user may want to copy: selectable, and the panel holds still while they drag
    /// across it.
    func selectableText() -> some View { modifier(SelectableTextModifier()) }
}
