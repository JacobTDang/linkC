import LinkCKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Lets a linkC terminal be dropped on this terminal's edges to split with it. While a drag
    /// hovers, the half of the pane the drop would land on is outlined. The dragged terminal is only
    /// known once it is dropped, so a drop that can't be honoured is reported then, in the error bar.
    func terminalDropTarget(model: AppModel, target: String?) -> some View {
        modifier(TerminalDropTargetModifier(model: model, target: target))
    }
}

private struct TerminalDropTargetModifier: ViewModifier {
    let model: AppModel
    let target: String?
    @State private var hovered: SplitEdge?
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .overlay(alignment: .topLeading) {
                EdgeHighlight(edge: hovered, size: size).allowsHitTesting(false)
            }
            .onDrop(of: [.linkcTerminal], delegate: TerminalDropDelegate(
                model: model, target: target, size: size, hovered: $hovered))
    }
}

/// The half of a `size` pane beside `edge`, in the accent colour at low opacity.
private struct EdgeHighlight: View {
    let edge: SplitEdge?
    let size: CGSize

    var body: some View {
        if let edge {
            let horizontal = edge == .left || edge == .right
            let shape = RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
            shape
                .fill(Theme.accent.opacity(0.12))
                .overlay(shape.stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                .frame(width: horizontal ? size.width / 2 : size.width,
                       height: horizontal ? size.height : size.height / 2)
                .offset(x: edge == .right ? size.width / 2 : 0, y: edge == .bottom ? size.height / 2 : 0)
                .animation(Theme.hoverEase, value: edge)
        }
    }
}

/// Hovering only moves the view's own highlight. The model is touched once, on the main actor, after
/// the dropped terminal's id has loaded.
@MainActor
private struct TerminalDropDelegate: DropDelegate {
    let model: AppModel
    let target: String?
    let size: CGSize
    @Binding var hovered: SplitEdge?

    func validateDrop(info: DropInfo) -> Bool {
        target != nil && info.hasItemsConforming(to: [.linkcTerminal])
    }

    func dropEntered(info: DropInfo) {
        hovered = SplitLayout.edge(at: info.location, in: size)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let edge = SplitLayout.edge(at: info.location, in: size)
        if hovered != edge { hovered = edge }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { hovered = nil }

    func performDrop(info: DropInfo) -> Bool {
        let edge = SplitLayout.edge(at: info.location, in: size)
        hovered = nil
        guard let target, let provider = info.itemProviders(for: [.linkcTerminal]).first else { return false }
        let model = model
        _ = provider.loadTransferable(type: LinkCTerminalDrag.self) { result in
            Task { @MainActor in
                switch result {
                case .success(let drag):
                    model.dropTerminal(drag.id, onto: target, edge: edge)
                case .failure(let error):
                    model.surface(error: "Couldn't read the dragged terminal: \(error.localizedDescription)")
                }
            }
        }
        return true
    }
}
