import Foundation
import TheiaKit

/// Linux session restoration and debounced autosave using the shared XDG store.
@MainActor final class GTKSessionPersistence {
    let session: DocumentSession
    let store: SessionStore
    let identity: SessionStore.FileIdentity?
    private(set) var staleState: SessionState?
    private(set) var warningMessage: String?
    var onWarning: (@MainActor (String) -> Void)?
    private var observerID: UUID?
    private var pendingSave: Task<Void, Never>?
    private var unsaved = false
    private var selectedHDU: Int
    private var selectedPlane: Int
    private let debounceNanoseconds: UInt64

    init(session: DocumentSession, fileData: Data,
         paths: AppPaths = AppPaths(platform: .linux),
         debounceNanoseconds: UInt64 = 500_000_000) {
        self.session = session
        store = SessionStore(paths: paths)
        self.debounceNanoseconds = debounceNanoseconds
        selectedHDU = session.hdu
        selectedPlane = session.plane
        var loadedIdentity: SessionStore.FileIdentity?
        do {
            let found = try SessionStore.identity(for: fileData)
            loadedIdentity = found
            switch try store.load(for: session.url, identity: found) {
            case .none: break
            case .restored(let state):
                session.restoreInitialState(state)
            case .restoredWithStale(let current, let stale):
                session.restoreInitialState(current)
                staleState = stale
            case .stale(let stale):
                staleState = stale
            }
        } catch {
            warningMessage = error.localizedDescription
        }
        identity = loadedIdentity
        selectedHDU = session.blink?.primary ?? session.hdu
        selectedPlane = session.plane
    }

    func start() {
        guard observerID == nil else { return }
        observerID = session.addEventObserver { [weak self] event in
            guard let self, event.kind == .persistedFieldChanged else { return }
            if !self.session.playing && self.session.blink == nil {
                self.selectedHDU = self.session.hdu
                self.selectedPlane = self.session.plane
            }
            self.schedule()
        }
    }

    func close() {
        pendingSave?.cancel()
        pendingSave = nil
        if unsaved { savePending() }
        if let observerID {
            session.removeEventObserver(observerID)
            self.observerID = nil
        }
    }

    func restoreStale() {
        guard let staleState else { return }
        session.restoreInitialState(staleState)
        self.staleState = nil
        selectedHDU = session.blink?.primary ?? session.hdu
        selectedPlane = session.plane
        schedule()
    }

    func discardStale() {
        do {
            try store.discardStale(for: session.url)
            staleState = nil
            schedule()
        } catch {
            report(error)
        }
    }

    private func schedule() {
        guard identity != nil else { return }
        unsaved = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            savePending()
        }
    }

    private func savePending() {
        guard unsaved, let identity else { return }
        do {
            try store.save(snapshot(), for: session.url, identity: identity)
            unsaved = false
            warningMessage = nil
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        guard message != warningMessage else { return }
        warningMessage = message
        onWarning?(message)
    }

    private func snapshot() -> SessionState {
        let contour = session.contourSpec
        return SessionState(
            selectedHDU: session.blink?.primary ?? selectedHDU,
            selectedPlane: selectedPlane,
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
                enabled: contour.enabled, count: contour.count,
                minValue: contour.minValue, maxValue: contour.maxValue,
                spacing: contour.spacing.rawValue
            )
        )
    }
}
