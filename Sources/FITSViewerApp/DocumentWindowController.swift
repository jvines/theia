import AppKit
import SwiftUI
import FITSCore
import TheiaKit

/// One window per opened FITS file. Owns the `NSWindow`, the `NSToolbar`
/// (via `FITSToolbarController`), and the SwiftUI content view hosted in an
/// `NSHostingView`.
@MainActor
final class DocumentWindowController: NSWindowController {
    let documentModel: DocumentModel
    let toolbarState: ToolbarState
    let toolbarController: FITSToolbarController
    let pixelTableBridge = PixelTableCursorBridge()
    private let pulseSource: PlaybackDisplayLink
    private let frameDriver: SessionFrameDriver

    init(document: DocumentModel) {
        self.documentModel = document
        let state = ToolbarState(session: document.session)
        self.toolbarState = state
        self.toolbarController = FITSToolbarController(state: state)
        let pulseSource = PlaybackDisplayLink()
        self.pulseSource = pulseSource
        let frameDriver = SessionFrameDriver(
            session: document.session,
            startPulses: { pulseSource.start() },
            stopPulses: { pulseSource.stop() }
        )
        self.frameDriver = frameDriver

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = documentModel.url.lastPathComponent
        window.subtitle = DocumentText.windowSubtitle(for: documentModel.file)
        window.minSize = NSSize(width: 700, height: 500)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("FITSViewerDocumentWindow")
        super.init(window: window)
        pulseSource.onPulse = { [weak frameDriver] now in frameDriver?.pulse(now: now) }

        let toolbar = toolbarController.makeToolbar()
        window.toolbar = toolbar
        NSLog("[DocumentWindowController] toolbar set, identifiers: \(toolbar.items.map(\.itemIdentifier.rawValue))")

        let view = DocumentView(
            document: documentModel,
            toolbarState: toolbarState,
            toolbarController: toolbarController,
            pixelTableBridge: pixelTableBridge
        )
        window.contentView = NSHostingView(rootView: view)

        window.delegate = self
        WindowSyncCoordinator.shared.register(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func bindOpenPanels() {
        let session = documentModel.session
        pixelTableBridge.cursor = session.cursor
        pixelTableBridge.imageRevision = session.imageRevision
        PixelTableWindowController.focus(provider: { [weak session] in session?.displayed },
                                         cursorPublisher: pixelTableBridge)
        ContourLevelsWindowController.focus(modelProvider: {
            let range = session.displayed.flatMap { PixelStatistics.minMax($0.physicalValues()) }
            return ContourLevelsModel(initial: session.contourSpec,
                                      dataMin: range?.min ?? .nan,
                                      dataMax: range?.max ?? .nan)
        }, onChange: { [weak session] spec in
            _ = session?.perform(.setContourSpec(spec), origin: .user)
        })
    }

}

extension DocumentWindowController {
    func regionsForScripting() -> [Region] { documentModel.session.regions }
    func setRegionsForScripting(_ regs: [Region]) {
        _ = documentModel.session.perform(.replaceRegions(regs), origin: .script)
    }
    func currentOverrideImage() -> FITSImage? { documentModel.session.displayed }
}

extension DocumentWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.shared?.controllerDidFocus(self)
        bindOpenPanels()
    }

    func windowWillClose(_ notification: Notification) {
        ScaleParametersWindowController.close(for: documentModel.session.view)
        documentModel.session.close()
        frameDriver.close()
        pulseSource.stop()
        WindowSyncCoordinator.shared.unregister(self)
        AppDelegate.shared?.controllerDidClose(self)
        if let next = AppDelegate.shared?.currentController {
            next.bindOpenPanels()
        } else {
            PixelTableWindowController.shared?.window?.close()
            ContourLevelsWindowController.shared?.window?.close()
        }
    }
}
