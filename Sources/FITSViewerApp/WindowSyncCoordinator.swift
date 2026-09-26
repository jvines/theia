import AppKit
import Combine
import FITSCore
import FITSRender

/// App-wide coordinator that, when enabled, broadcasts viewport / scale / colormap
/// changes from one document window to every other open document window. Lets users
/// compare two FITS files side-by-side with synchronised view state.
///
/// Each `DocumentWindowController` registers its viewport / toolbar state on init
/// and unregisters on close.
@MainActor
final class WindowSyncCoordinator: ObservableObject {
    static let shared = WindowSyncCoordinator()

    @Published var matchZoom: Bool = false
    @Published var matchColormap: Bool = false
    @Published var matchScale: Bool = false
    @Published var matchCrosshair: Bool = false

    private var entries: [Entry] = []
    private var suppressBroadcast = false

    private struct Entry {
        weak var controller: DocumentWindowController?
        var subscriptions: Set<AnyCancellable> = []
    }

    func register(_ controller: DocumentWindowController) {
        // Clean dead references opportunistically.
        entries.removeAll { $0.controller == nil }
        var entry = Entry(controller: controller)
        let viewport = controller.documentModel.viewport
        let toolbar = controller.toolbarState

        viewport.$transform.sink { [weak self] new in
            self?.broadcastTransform(new, from: controller)
        }.store(in: &entry.subscriptions)

        viewport.$vmin.combineLatest(viewport.$vmax).sink { [weak self] (lo, hi) in
            self?.broadcastScale(vmin: lo, vmax: hi, from: controller)
        }.store(in: &entry.subscriptions)

        toolbar.$colorMap.sink { [weak self] new in
            self?.broadcastColormap(new, from: controller)
        }.store(in: &entry.subscriptions)

        entries.append(entry)
    }

    func unregister(_ controller: DocumentWindowController) {
        entries.removeAll { $0.controller === controller || $0.controller == nil }
    }

    // MARK: - Broadcasts

    private func broadcastTransform(_ t: ViewTransform, from origin: DocumentWindowController) {
        guard matchZoom, !suppressBroadcast else { return }
        suppressBroadcast = true
        defer { suppressBroadcast = false }
        for entry in entries {
            guard let c = entry.controller, c !== origin else { continue }
            c.documentModel.viewport.transform = t
            c.window?.contentView?.needsDisplay = true
        }
    }

    private func broadcastScale(vmin: Float, vmax: Float, from origin: DocumentWindowController) {
        guard matchScale, !suppressBroadcast else { return }
        suppressBroadcast = true
        defer { suppressBroadcast = false }
        for entry in entries {
            guard let c = entry.controller, c !== origin else { continue }
            c.documentModel.viewport.vmin = vmin
            c.documentModel.viewport.vmax = vmax
        }
    }

    private func broadcastColormap(_ cm: ColorMap, from origin: DocumentWindowController) {
        guard matchColormap, !suppressBroadcast else { return }
        suppressBroadcast = true
        defer { suppressBroadcast = false }
        for entry in entries {
            guard let c = entry.controller, c !== origin else { continue }
            c.toolbarState.colorMap = cm
            c.toolbarState.onSelectMap(cm)
        }
    }

    /// Broadcast a cursor position from `origin`. Other windows receive the matching
    /// pixel — via WCS if both have it, else the same (x, y) pixel.
    func broadcastCursor(imagePoint: SIMD2<Double>, from origin: DocumentWindowController, sourceWCS: WCS?) {
        guard matchCrosshair, !suppressBroadcast else { return }
        suppressBroadcast = true
        defer { suppressBroadcast = false }
        let sky: (ra: Double, dec: Double)? = sourceWCS?.pixelToSky(
            imageX: Int(imagePoint.x.rounded()), imageY: Int(imagePoint.y.rounded()))
        for entry in entries {
            guard let c = entry.controller, c !== origin else { continue }
            // Try to translate via WCS if both sides have it.
            var localPoint = imagePoint
            if let sky,
               let targetWCS = c.documentModel.session.displayedWCS,
               let p = targetWCS.skyToPixel(ra: sky.ra, dec: sky.dec) {
                localPoint = SIMD2(p.x, p.y)
            }
            c.documentModel.remoteCrosshair = localPoint
        }
    }

    func clearCrosshairs(except origin: DocumentWindowController? = nil) {
        for entry in entries {
            guard let c = entry.controller, c !== origin else { continue }
            c.documentModel.remoteCrosshair = nil
        }
    }

    // MARK: - Tile

    /// Arrange all registered windows in a horizontal row across the active screen.
    func tileWindowsHorizontally() {
        let liveControllers = entries.compactMap { $0.controller }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame, !liveControllers.isEmpty else { return }
        let count = CGFloat(liveControllers.count)
        let w = frame.width / count
        for (i, c) in liveControllers.enumerated() {
            let f = NSRect(x: frame.minX + CGFloat(i) * w, y: frame.minY,
                           width: w, height: frame.height)
            c.window?.setFrame(f, display: true, animate: true)
        }
    }
}
