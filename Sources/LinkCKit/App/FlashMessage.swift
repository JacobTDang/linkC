import Foundation
import Observation

/// A message shown for a moment, then cleared — the panel's error strip. An empty or blank message
/// shows nothing. Each message gets its own clock, and a newer message is never cleared by an
/// older one's clock running out. `sleep` is injected so tests control time.
@MainActor
@Observable
public final class FlashMessage {
    public private(set) var text: String?

    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    /// Bumped by every `show`, so a clock knows whether its message is still the one on screen.
    @ObservationIgnored private var generation = 0

    public init(
        duration: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            // A cancelled sleep only ends the wait early; the generation check still decides.
            try? await Task.sleep(for: duration)
        }
    ) {
        self.duration = duration
        self.sleep = sleep
    }

    /// Show `message` for `duration`, replacing whatever was showing. nil, empty, or blank clears
    /// at once.
    public func show(_ message: String?) {
        generation += 1
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            text = nil
            return
        }
        text = trimmed
        let shown = generation
        let sleep = self.sleep
        let duration = self.duration
        Task { [weak self] in
            await sleep(duration)
            guard let self, self.generation == shown else { return }
            self.text = nil
        }
    }
}
