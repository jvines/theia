import AppKit
import SwiftUI
import FITSCore

/// One window per opened FITS file. Owns the `NSWindow`, the `NSToolbar`
/// (via `FITSToolbarController`), and the SwiftUI content view hosted in an
/// `NSHostingView`.
@MainActor
final class DocumentWindowController: NSWindowController {
    let documentModel: DocumentModel
    let toolbarState: ToolbarState
    let toolbarController: FITSToolbarController

    init(document: DocumentModel) {
        self.documentModel = document
        let state = ToolbarState()
        self.toolbarState = state
        self.toolbarController = FITSToolbarController(state: state)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = documentModel.url.lastPathComponent
        window.subtitle = Self.subtitle(for: documentModel)
        window.minSize = NSSize(width: 700, height: 500)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("FITSViewerDocumentWindow")
        super.init(window: window)

        let toolbar = toolbarController.makeToolbar()
        window.toolbar = toolbar
        NSLog("[DocumentWindowController] toolbar set, identifiers: \(toolbar.items.map(\.itemIdentifier.rawValue))")

        let view = DocumentView(
            document: documentModel,
            toolbarState: toolbarState,
            toolbarController: toolbarController
        )
        window.contentView = NSHostingView(rootView: view)

        window.delegate = self
        WindowSyncCoordinator.shared.register(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// At-a-glance file stats for the window subtitle.
    static func subtitle(for model: DocumentModel) -> String {
        let n = model.file.hdus.count
        let imageHDU = model.file.hdus.first(where: { $0.isImage && $0.naxis >= 2 })
        var parts = ["\(n) HDU\(n == 1 ? "" : "s")"]
        if let h = imageHDU {
            parts.append(h.shapeDescription)
            parts.append(h.bitpixLabel)
        }
        return parts.joined(separator: " · ")
    }
}

extension DocumentWindowController {
    func regionsForScripting() -> [Region] { documentModel.regionsBridge }
    func setRegionsForScripting(_ regs: [Region]) { documentModel.setRegions(regs) }
    func currentOverrideImage() -> FITSImage? { documentModel.currentImageProvider() }
}

extension DocumentWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        WindowSyncCoordinator.shared.unregister(self)
        AppDelegate.shared?.controllerDidClose(self)
    }
}
