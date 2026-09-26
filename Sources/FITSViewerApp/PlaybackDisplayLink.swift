import Foundation
import CoreVideo

/// Mac display pulses for an active document. CoreVideo calls on a render
/// thread; document state is touched only after hopping to the main actor.
@MainActor final class PlaybackDisplayLink {
    var onPulse: (@MainActor (Date) -> Void)?
    private var link: CVDisplayLink?
    private var fallbackTimer: DispatchSourceTimer?

    func start() {
        guard link == nil, fallbackTimer == nil else { return }
        var created: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
           let created {
            let handler: CVDisplayLinkOutputHandler = { [weak self] _, _, _, _, _ in
                self?.postPulse()
                return kCVReturnSuccess
            }
            if CVDisplayLinkSetOutputHandler(created, handler) == kCVReturnSuccess,
               CVDisplayLinkStart(created) == kCVReturnSuccess {
                link = created
                return
            }
        }
        // Headless and remote sessions may have no active CoreVideo display.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667))
        timer.setEventHandler { [weak self] in self?.onPulse?(Date()) }
        fallbackTimer = timer
        timer.resume()
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    nonisolated private func postPulse() {
        Task { @MainActor [weak self] in self?.onPulse?(Date()) }
    }
}
