import SwiftUI
import LinkCKit

private struct PanelVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelVisible: Bool {
        get { self[PanelVisibleKey.self] }
        set { self[PanelVisibleKey.self] = newValue }
    }
}

/// Clean, smooth highlighting that glides across text when active — matching the ChatGPT / Perplexity status design.
struct SmoothShimmerModifier: ViewModifier {
    let isWorking: Bool

    @State private var phase: CGFloat = 0
    @State private var isOnScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    private var shouldAnimate: Bool {
        ShimmerPolicy.shouldAnimate(
            isWorking: isWorking,
            isOnScreen: isOnScreen,
            panelVisible: panelVisible,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if shouldAnimate {
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
            }
            .onAppear {
                isOnScreen = true
            }
            .onDisappear {
                isOnScreen = false
            }
            .onChange(of: shouldAnimate) { _, animate in
                if animate {
                    startAnimation()
                } else {
                    stopAnimation()
                }
            }
    }

    private func startAnimation() {
        guard shouldAnimate else { return }
        phase = 0
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
            phase = 1.0
        }
    }

    private func stopAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = 0
        }
    }
}

extension View {
    /// Applies a clean, smooth highlighting wave across text letters when active.
    func smoothShimmer(isWorking: Bool) -> some View {
        modifier(SmoothShimmerModifier(isWorking: isWorking))
    }

    /// Applies a faint hairline light that glides along the bottom of a working row.
    func hairlineSweep(isWorking: Bool) -> some View {
        modifier(HairlineSweepModifier(isWorking: isWorking))
    }
}

/// A hairline light that runs along the bottom of a working row.
struct HairlineSweepModifier: ViewModifier {
    let isWorking: Bool

    @State private var phase: CGFloat = 0
    @State private var isOnScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    private var shouldAnimate: Bool {
        ShimmerPolicy.shouldAnimate(
            isWorking: isWorking,
            isOnScreen: isOnScreen,
            panelVisible: panelVisible,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if shouldAnimate {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let bandWidth = max(width * HairlineSweep.bandFraction, HairlineSweep.minimumBandWidth)
                        let travel = width + bandWidth
                        LinearGradient(
                            stops: HairlineSweep.stops.map { stop in
                                .init(color: .white.opacity(stop.opacity), location: stop.location)
                            },
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth, height: 1)
                        .offset(x: -bandWidth + phase * travel)
                    }
                    .frame(height: 1)
                    .clipped()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 3)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                isOnScreen = true
            }
            .onDisappear {
                isOnScreen = false
            }
            .onChange(of: shouldAnimate) { _, animate in
                if animate {
                    startAnimation()
                } else {
                    stopAnimation()
                }
            }
    }

    private func startAnimation() {
        guard shouldAnimate else { return }
        phase = 0
        withAnimation(.easeInOut(duration: HairlineSweep.period).repeatForever(autoreverses: false)) {
            phase = 1.0
        }
    }

    private func stopAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = 0
        }
    }
}

/// A coral dot marking an agent that needs attention (unseen done or permission required).
/// For permission prompts (`pingDot`), it sends out a slow expanding ring.
struct StatusDotView: View {
    let marker: SessionRowStatus.Marker

    @State private var phase: CGFloat = 0
    @State private var isOnScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible

    private var shouldAnimate: Bool {
        ShimmerPolicy.shouldAnimate(
            isWorking: marker == .pingDot,
            isOnScreen: isOnScreen,
            panelVisible: panelVisible,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        if marker != .none {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)
                .overlay {
                    if shouldAnimate {
                        Circle()
                            .stroke(Theme.accent, lineWidth: 1.5)
                            .frame(width: 7, height: 7)
                            .scaleEffect(1.0 + phase * 1.6)
                            .opacity(0.9 * (1.0 - Double(phase)))
                            .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    isOnScreen = true
                }
                .onDisappear {
                    isOnScreen = false
                }
                .onChange(of: shouldAnimate) { _, animate in
                    if animate {
                        startAnimation()
                    } else {
                        stopAnimation()
                    }
                }
        }
    }

    private func startAnimation() {
        guard shouldAnimate else { return }
        phase = 0
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1.0
        }
    }

    private func stopAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = 0
        }
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
