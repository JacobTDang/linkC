import SwiftUI

/// Clean, smooth highlighting that glides across text when active — matching the ChatGPT / Perplexity status design.
struct SmoothShimmerModifier: ViewModifier {
    let isWorking: Bool
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isWorking && !reduceMotion {
            content
                .overlay {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let bandWidth = max(width * 0.45, 30)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white.opacity(0.85), location: 0.5),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .offset(x: -bandWidth + phase * (width + bandWidth * 2))
                    }
                    .mask(content)
                }
                .onAppear {
                    startAnimation()
                }
                .onChange(of: isWorking) { _, working in
                    if working {
                        startAnimation()
                    } else {
                        phase = 0
                    }
                }
                .onChange(of: reduceMotion) { _, _ in
                    if isWorking { startAnimation() }
                }
        } else {
            content
        }
    }

    private func startAnimation() {
        guard !reduceMotion else { return }
        phase = 0
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
            phase = 1.0
        }
    }
}

extension View {
    /// Applies a clean, smooth highlighting wave across text letters when active.
    func smoothShimmer(isWorking: Bool) -> some View {
        modifier(SmoothShimmerModifier(isWorking: isWorking))
    }
}

/// Helper mapping an activity description string to an appropriate SF Symbol icon.
func activityIcon(for activity: String?) -> String {
    guard let act = activity?.lowercased() else { return "sparkles" }
    if act.contains("search") || act.contains("find") || act.contains("lookup") || act.contains("website") {
        return "globe"
    }
    if act.contains("read") || act.contains("fetch") {
        return "doc.text"
    }
    if act.contains("write") || act.contains("edit") || act.contains("update") || act.contains("replace") {
        return "pencil"
    }
    if act.contains("test") || act.contains("swift") || act.hasPrefix("$") || act.contains("run") || act.contains("build") {
        return "terminal"
    }
    if act.contains("think") || act.contains("generat") || act.contains("saute") || act.contains("boondoggl") {
        return "sparkles"
    }
    return "sparkles"
}
