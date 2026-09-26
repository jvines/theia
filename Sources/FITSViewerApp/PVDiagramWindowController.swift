import AppKit
import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

/// Floating panel showing a position-velocity diagram extracted from a cube. The PV
/// image is rendered as a standalone Metal view so it gets the same stretch / colour
/// map controls as the main image (initially: zscale + viridis).
@MainActor
final class PVDiagramWindowController: NSWindowController {
    static private(set) var shared: PVDiagramWindowController?

    static func show(image: FITSImage, imageName: String, attachedTo parent: NSWindow?) {
        let view = PVDiagramView(image: image)
        if let existing = shared {
            existing.window?.contentView = NSHostingView(rootView: view)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "PV Diagram — \(imageName)"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: view)
        if let parent {
            panel.setFrameOrigin(NSPoint(x: parent.frame.minX + 60, y: parent.frame.minY + 60))
        } else { panel.center() }
        let c = PVDiagramWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension PVDiagramWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct PVDiagramView: View {
    let image: FITSImage
    @StateObject private var viewport: ViewportObservable

    init(image: FITSImage) {
        self.image = image
        let levels = DocumentSession.recommendedLevels(for: image)
        self._viewport = StateObject(wrappedValue: ViewportObservable(vmin: levels.vmin, vmax: levels.vmax))
    }

    var body: some View {
        VStack(spacing: 0) {
            FITSMetalView(
                image: image,
                imageRevision: 0,
                stretch: .linear,
                colorMap: .viridis,
                viewport: viewport
            )
            HStack {
                Text("position →").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("← plane").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }
}
