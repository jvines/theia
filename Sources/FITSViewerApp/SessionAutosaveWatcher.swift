import Foundation
import Observation
import FITSCore
import TheiaKit

/// Observes the session's persisted-field events and saves one snapshot after
/// 0.5 seconds of quiet. Display pulses emit no such event.
@MainActor @Observable
final class SessionAutosaveWatcher {
    private let session: DocumentSession
    private let debounceNanoseconds: UInt64
    private let save: (SessionState) throws -> Void
    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var lastFailureCause: String?
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var userSelectedHDU: Int
    @ObservationIgnored private var userSelectedPlane: Int

    private(set) var failureNoticeID = 0
    private(set) var failureMessage: String?

    init(session: DocumentSession, debounceNanoseconds: UInt64 = 500_000_000,
         save: @escaping (SessionState) throws -> Void) {
        self.session = session
        self.debounceNanoseconds = debounceNanoseconds
        self.save = save
        userSelectedHDU = session.blink?.primary ?? session.hdu
        userSelectedPlane = session.plane
    }

    func start() {
        guard observerID == nil else { return }
        userSelectedHDU = session.blink?.primary ?? session.hdu
        if !session.playing { userSelectedPlane = session.plane }
        observerID = session.addEventObserver { [weak self] event in
            guard let self, event.kind == .persistedFieldChanged else { return }
            if !self.session.playing && self.session.blink == nil {
                self.userSelectedHDU = self.session.hdu
                self.userSelectedPlane = self.session.plane
            }
            self.schedule()
        }
    }

    func close() {
        pendingSave?.cancel()
        pendingSave = nil
        if hasUnsavedChanges { savePendingChanges() }
        if let observerID {
            session.removeEventObserver(observerID)
            self.observerID = nil
        }
    }

    func dismissFailure() {
        failureMessage = nil
    }

    func schedule() {
        hasUnsavedChanges = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
                savePendingChanges()
            } catch is CancellationError {
                return
            } catch {
                reportFailure(error)
            }
        }
    }

    private func savePendingChanges() {
        guard hasUnsavedChanges else { return }
        do {
            try save(snapshot())
            hasUnsavedChanges = false
            failureMessage = nil
            lastFailureCause = nil
        } catch {
            reportFailure(error)
        }
    }

    private func reportFailure(_ error: Error) {
        let cause = error.localizedDescription
        if cause != lastFailureCause {
            lastFailureCause = cause
            failureMessage = cause
            failureNoticeID &+= 1
        }
    }

    private func snapshot() -> SessionState {
        let contour = session.contourSpec
        return SessionState(
            selectedHDU: session.blink?.primary ?? userSelectedHDU,
            selectedPlane: userSelectedPlane,
            stretch: session.view.stretch,
            colorMap: session.view.colorMap,
            drawMode: session.mode,
            vmin: Double(session.view.vmin),
            vmax: Double(session.view.vmax),
            stretchParameter: Double(session.view.stretchParameter),
            showWCSGrid: session.showGrid,
            showCompass: session.showCompass,
            showColorBar: session.showColorBar,
            regions: session.regions,
            contour: SessionState.Contour(
                enabled: contour.enabled,
                count: contour.count,
                minValue: contour.minValue,
                maxValue: contour.maxValue,
                spacing: contour.spacing.rawValue
            )
        )
    }
}
