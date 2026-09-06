import SwiftUI

/// ViewModifier applying an OpenAI-style sweeping linear gradient highlight loop across content
/// when active.
struct ShimmerHighlightModifier: ViewModifier {
    let isWorking: Bool

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isWorking {
            content
                .mask {
                    if !reduceMotion {
                        GeometryReader { geo in
                            let width = geo.size.width
                            let beamWidth = max(width * 0.8, 60)
                            ZStack {
                                Color.white.opacity(0.4)
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .white.opacity(0.6), location: 0.5),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: beamWidth)
                                .offset(x: -beamWidth + phase * (width + beamWidth * 2))
                            }
                        }
                    } else {
                        Color.white
                    }
                }
                .overlay {
                    if !reduceMotion {
                        GeometryReader { geo in
                            let width = geo.size.width
                            let beamWidth = max(width * 0.8, 60)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .white.opacity(0.25), location: 0.5),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: beamWidth)
                            .offset(x: -beamWidth + phase * (width + beamWidth * 2))
                        }
                        .mask(content)
                    }
                }
                .onAppear {
                    if isWorking {
                        startAnimation()
                    }
                }
                .onChange(of: isWorking) { _, working in
                    if working {
                        startAnimation()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            phase = 0
                        }
                    }
                }
                .onChange(of: reduceMotion) { _, _ in
                    if isWorking {
                        startAnimation()
                    }
                }
        } else {
            content
        }
    }

    private func startAnimation() {
        guard !reduceMotion else { return }
        phase = 0
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
            phase = 1.0
        }
    }
}

extension View {
    /// Applies an OpenAI-style sweeping gradient highlight loop when `isWorking` is true.
    func shimmerHighlight(isWorking: Bool) -> some View {
        modifier(ShimmerHighlightModifier(isWorking: isWorking))
    }
}
