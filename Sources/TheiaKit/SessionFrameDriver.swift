import Foundation

/// Starts the host's display pulses only while a document needs time updates.
/// The host supplies a platform display link and calls `pulse(now:)` for each
/// frame. The session decides whether a pulse advances playback or blink.
@MainActor public final class SessionFrameDriver {
    private let session: DocumentSession
    private let startPulses: @MainActor () -> Void
    private let stopPulses: @MainActor () -> Void
    private var observerID: UUID?
    private var closed = false
    public private(set) var isRunning = false

    public init(
        session: DocumentSession,
        startPulses: @escaping @MainActor () -> Void,
        stopPulses: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.startPulses = startPulses
        self.stopPulses = stopPulses
        observerID = session.addEventObserver { [weak self] event in
            if event.kind == .playbackChanged { self?.refresh() }
        }
        refresh()
    }

    public func pulse(now: Date) {
        guard isRunning, !closed else { return }
        session.tick(now: now)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        if let observerID { session.removeEventObserver(observerID) }
        observerID = nil
        if isRunning {
            isRunning = false
            stopPulses()
        }
    }

    private func refresh() {
        guard !closed else { return }
        let shouldRun = session.playing || session.blink != nil
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun { startPulses() } else { stopPulses() }
    }
}
