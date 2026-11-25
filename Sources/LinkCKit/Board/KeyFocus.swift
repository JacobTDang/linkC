import AppKit
import SwiftUI

extension KeyFocus {
    /// Where `responder`, a window's first responder, sits. Inside a terminal is the terminal; a text
    /// field's or editor's is text. Chrome is an allowlist: nothing, the window, or a view that AppKit,
    /// SwiftUI or linkC itself drew, from it up to the window's content view. Anything else, such as a
    /// `WKWebView` in an app tab or a view inside one, is embedded.
    @MainActor
    public static func of(_ responder: NSResponder?) -> KeyFocus {
        guard let responder, !(responder is NSWindow) else { return .chrome }
        if responder is NSText { return .text }
        guard let view = responder as? NSView else { return .embedded }
        var chain: [NSView] = []
        var next: NSView? = view
        while let current = next {
            chain.append(current)
            next = current === current.window?.contentView ? nil : current.superview
        }
        if chain.contains(where: { $0 is LinkCTerminalView }) { return .terminal }
        return chain.allSatisfy { chromeBundles.contains(Bundle(for: type(of: $0)).bundleURL) } ? .chrome : .embedded
    }

    /// Where the classes of linkC's own views come from: AppKit, SwiftUI, LinkCKit and the app.
    @MainActor
    private static let chromeBundles: Set<URL> = [
        Bundle(for: NSView.self).bundleURL,
        Bundle(for: NSHostingView<EmptyView>.self).bundleURL,
        Bundle(for: LinkCTerminalView.self).bundleURL,
        Bundle.main.bundleURL,
    ]
}
