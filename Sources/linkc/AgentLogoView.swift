import AppKit
import SwiftUI
import LinkCKit

/// An agent's logo, drawn from its embedded SVG; a plain shell's terminal symbol. Each logo is
/// loaded once. A logo that fails to load is a broken embed — `AgentLogoTests` guards it — so it
/// traps rather than showing a blank.
struct AgentLogoView: View {
    let agent: AgentKind
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let logo = agent.logo {
                Image(nsImage: AgentLogoImages.image(for: agent, logo: logo))
                    .renderingMode(logo.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

@MainActor
private enum AgentLogoImages {
    private static var cache: [AgentKind: NSImage] = [:]

    static func image(for agent: AgentKind, logo: AgentLogo) -> NSImage {
        if let cached = cache[agent] { return cached }
        guard let image = NSImage(data: Data(logo.svg.utf8)), image.isValid else {
            preconditionFailure("the embedded \(agent.displayName) logo does not load as SVG")
        }
        image.isTemplate = logo.isTemplate
        cache[agent] = image
        return image
    }
}
