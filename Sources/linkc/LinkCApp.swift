import SwiftUI
import AppKit
import LinkCKit

/// Menu bar shell. Wiring of KittyController / HookServer / NotificationManager is
/// completed in the App-integration task; this compiles against the current contracts
/// and renders live aggregate status from the store.
@main
struct LinkCApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            LinkCMenu(store: store)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct LinkCMenu: View {
    let store: SessionStore

    var body: some View {
        Text("linkC")
        Text("\(store.activeCount) running · \(store.needsYouCount) waiting")
            .font(.caption)
        Divider()
        if store.sessions.isEmpty {
            Text("No sessions yet").foregroundStyle(.secondary)
        } else {
            ForEach(store.sessions) { session in
                Text("\(session.title) — \(session.state.rawValue)")
            }
        }
        Divider()
        Button("Quit linkC") { NSApplication.shared.terminate(nil) }
    }
}
