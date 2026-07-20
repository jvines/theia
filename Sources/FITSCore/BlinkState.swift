import Foundation

/// Drives the "blink" alternation between two HDUs. `currentHDU(at:)` is pure and
/// deterministic for a given configuration, so the UI just needs a timer that calls
/// it on each tick.
public struct BlinkState: Sendable, Equatable {
    public let primary: Int
    public let partner: Int
    public let intervalSeconds: Double
    public let startedAt: Date

    public init(primary: Int, partner: Int, intervalSeconds: Double, startedAt: Date) {
        self.primary = primary
        self.partner = partner
        self.intervalSeconds = intervalSeconds
        self.startedAt = startedAt
    }

    public func currentHDU(at time: Date) -> Int {
        let halfPeriod = intervalSeconds / 2
        guard halfPeriod > 0 else { return primary }
        let elapsed = time.timeIntervalSince(startedAt)
        let phase = Int((elapsed / halfPeriod).rounded(.down)) & 1
        return phase == 0 ? primary : partner
    }
}
