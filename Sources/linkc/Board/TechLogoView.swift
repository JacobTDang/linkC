import AppKit
import SwiftUI
import LinkCKit

/// A component's technology logo, drawn from its catalog SVG. Mirrors `AgentLogoView`: each logo
/// is loaded once, a dark brand renders as a template tinted to the board's text colour, and a
/// logo that fails to load is a broken embed — `BoardTechTests` guards the embed itself — so it
/// traps rather than showing a blank.
struct TechLogoView: View {
    let info: BoardTechInfo
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: TechLogoImages.image(for: info))
            .renderingMode(info.isDark ? .template : .original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
    }
}

@MainActor
private enum TechLogoImages {
    private static var cache: [String: NSImage] = [:]

    static func image(for info: BoardTechInfo) -> NSImage {
        if let cached = cache[info.id] { return cached }
        guard let image = NSImage(data: Data(info.svg.utf8)), image.isValid else {
            // `preconditionFailure` drops its message in a release build (`build-app.sh` builds
            // `-c release`); `fatalError` keeps it, so a broken embed still says which one.
            fatalError("the embedded \(info.id) logo does not load as SVG")
        }
        image.isTemplate = info.isDark
        cache[info.id] = image
        return image
    }
}
