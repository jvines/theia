import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FITSCore
import FITSRender
import XPABridge

/// App-level coordinator: handles file opens from Finder / drag-and-drop / the
/// Open menu, maintains one `DocumentWindowController` per opened FITS file, and
/// keeps NSDocumentController's Open Recent menu populated.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Process-wide singleton handle. `weak` is safe here because
    /// `@NSApplicationDelegateAdaptor` in `FITSViewerApp` holds the strong
    /// reference for the app's lifetime. If that adaptor is ever removed, this
    /// must become `strong` or be re-rooted to avoid going nil on the next
    /// runloop tick.
    static private(set) weak var shared: AppDelegate?

    private var controllers: [DocumentWindowController] = []

    /// Stable, monotonic scripting id per controller. Assigned at open and never
    /// reused, so closing a middle window doesn't renumber the others (a positional
    /// index would silently retarget any script holding an older id). Keyed by
    /// object identity because `DocumentWindowController` isn't `Hashable`.
    private var documentIDs: [ObjectIdentifier: Int] = [:]
    private var nextDocumentID = 0

    /// The document scripting clients act on by default: the most recently opened
    /// or raised window. Used when there's no key window (e.g. headless/scripted).
    private(set) weak var currentController: DocumentWindowController?

    private let xpaBridge = XPACommandBridge()
    private var xpaServer: XPAServer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        log("willFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("didFinishLaunching, args=\(CommandLine.arguments), controllers=\(controllers.count)")
        ScriptingServer.shared.start()
        startXPAServer()
        // If launched with a file path on argv (rare with .app bundles), open it.
        for arg in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) {
                openDocument(at: url)
            }
        }
        let hasSeenOnboarding = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
        if !hasSeenOnboarding {
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
            OnboardingWindowController.show()
        } else if controllers.isEmpty {
            WelcomeWindowController.show()
        }
    }

    /// Log file path: `~/Library/Logs/<bundle id>/app.log`. Owner-only readable
    /// (the default for files created under the user's home). Created on first
    /// write; no-op (best effort) if the filesystem refuses us.
    private static let logURL: URL = {
        let bundle = Bundle.main.bundleIdentifier ?? "com.athropa.theia"
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dir = home.appendingPathComponent("Library/Logs").appendingPathComponent(bundle)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private func log(_ msg: String) {
        let line = "[AppDelegate] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = Self.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Open paths

    func application(_ application: NSApplication, open urls: [URL]) {
        log("application(_:open:) urls=\(urls)")
        for url in urls {
            if url.scheme == "fitsviewer" {
                handleFITSViewerURL(url)
            } else {
                openDocument(at: url)
            }
        }
    }

    /// Custom URL handler:
    ///   fitsviewer://open?path=/abs/path[&stretch=asinh][&colormap=viridis][&vmin=0][&vmax=100][&zscale=1]
    /// Apply settings to the resulting document window. From AppleScript or shell:
    ///   open "fitsviewer://open?path=/tmp/x.fits&stretch=asinh"
    private func handleFITSViewerURL(_ url: URL) {
        log("handling fitsviewer URL: \(url.absoluteString)")
        guard url.host == "open",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              let pathItem = items.first(where: { $0.name == "path" })?.value
        else {
            log("URL missing required path parameter")
            return
        }
        let fileURL = URL(fileURLWithPath: pathItem)
        let controller: DocumentWindowController
        do {
            controller = try openDocumentThrowing(at: fileURL)
        } catch {
            log("fitsviewer URL open failed: \(error)")
            return
        }
        // Apply query params to the document state before any view appears.
        let session = controller.documentModel.session
        let viewport = session.view
        if let raw = items.first(where: { $0.name == "stretch" })?.value,
           let s = ImageStretch(rawValue: raw) {
            viewport.stretch = s
        }
        if let raw = items.first(where: { $0.name == "colormap" })?.value,
           let cm = ColorMap(rawValue: raw) {
            viewport.colorMap = cm
        }
        if let raw = items.first(where: { $0.name == "vmin" })?.value, let v = Float(raw) {
            viewport.vmin = v
        }
        if let raw = items.first(where: { $0.name == "vmax" })?.value, let v = Float(raw) {
            viewport.vmax = v
        }
        if items.first(where: { $0.name == "zscale" })?.value == "1" {
            session.resetLevels()
        }
    }

    @objc func openDocumentAction(_ sender: Any?) {
        presentOpenPanel()
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // .fz = tile-compressed FITS (decompressed transparently on open).
        let types = ["fits", "fz"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types + [.data]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.openDocument(at: url)
            }
        }
    }

    /// Re-open Welcome when the last document window closes (mirrors Pages / Xcode UX).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && controllers.isEmpty {
            WelcomeWindowController.show()
        }
        return true
    }

    /// Registers DS9-compatible XPA access points so xpaget/xpaset and pyds9 can
    /// drive the app. Prepends our own executable directory to PATH first so
    /// libxpa can find the bundled `xpans` name server it spawns for registration.
    private func startXPAServer() {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
            setenv("PATH", existing.isEmpty ? dir : "\(dir):\(existing)", 1)
        }
        let server = XPAServer(delegate: xpaBridge)
        server.start()
        xpaServer = server
        log("XPA server started (xpa \(XPABridge.version))")
    }

    /// Throwing core of the open path — performs **no UI**. Scripted callers
    /// (HTTP `/open`, XPA `file`, `fitsviewer://` URLs) use this so a failed open
    /// maps to an error return instead of blocking the main thread on a modal
    /// alert, which would freeze the app and all further scripting until a human
    /// clicks OK. Returns the controller now showing `url`.
    @discardableResult
    func openDocumentThrowing(at url: URL) throws -> DocumentWindowController {
        log("openDocument at \(url.path)")
        if let existing = controllers.first(where: { $0.documentModel.url == url }) {
            log("already open, raising")
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            currentController = existing
            return existing
        }
        let document = try DocumentModel(url: url)
        log("loaded \(document.file.hdus.count) HDUs")
        let controller = DocumentWindowController(document: document)
        controllers.append(controller)
        documentIDs[ObjectIdentifier(controller)] = nextDocumentID
        nextDocumentID += 1
        currentController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        WelcomeWindowController.closeIfOpen()
        log("window shown, toolbar items=\(controller.window?.toolbar?.items.count ?? -1)")
        return controller
    }

    /// GUI open wrapper: opens `url`, surfacing failures as a **non-blocking**
    /// alert. Only user-initiated paths (menu, drag-and-drop, Welcome window,
    /// argv) call this; scripted callers use `openDocumentThrowing` directly.
    func openDocument(at url: URL) {
        do {
            try openDocumentThrowing(at: url)
        } catch {
            log("open failed: \(error)")
            presentOpenError(error, url: url)
        }
    }

    /// Presents an open-failure alert without blocking the main runloop. Attaches
    /// a sheet to a host window when one exists; otherwise defers a standalone
    /// alert so the current call (e.g. launch-time argv handling) returns at once.
    private func presentOpenError(_ error: Error, url: URL) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn't open \(url.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        if let host = NSApp.keyWindow ?? controllers.first(where: { $0.window?.isVisible == true })?.window {
            alert.beginSheetModal(for: host, completionHandler: nil)
        } else {
            DispatchQueue.main.async { alert.runModal() }
        }
    }

    func controllerDidClose(_ controller: DocumentWindowController) {
        controllers.removeAll { $0 === controller }
        documentIDs[ObjectIdentifier(controller)] = nil   // don't renumber the survivors
    }

    // MARK: - Scripting bridge

    func allControllersForScripting() -> [DocumentWindowController] { controllers }

    /// Looks up a controller by its stable scripting id (not its array position).
    func controllerForScripting(at id: Int) -> DocumentWindowController? {
        controllers.first { documentIDs[ObjectIdentifier($0)] == id }
    }

    /// The stable scripting id assigned to `controller` at open (−1 if unknown).
    func scriptingID(of controller: DocumentWindowController) -> Int {
        documentIDs[ObjectIdentifier(controller)] ?? -1
    }
    func controllerForCurrentDocument(matching url: URL) -> DocumentWindowController? {
        controllers.first { $0.documentModel.url == url }
    }

    @objc func saveCurrentImageAsFITS() {
        let controller = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first
        guard let controller else { NSSound.beep(); return }
        let model = controller.documentModel
        guard let image = model.session.displayed else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
        panel.nameFieldStringValue = model.url.deletingPathExtension().lastPathComponent + "-modified.fits"
        guard let parent = controller.window else { return }
        panel.beginSheetModal(for: parent) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try FITSWriter.write(image, to: url)
            } catch {
                let a = NSAlert(error: error)
                a.runModal()
            }
        }
    }

    @objc func printFrontDocument() {
        // Find the controller whose window is currently key (or the first one).
        let controller = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first
        guard let controller else { NSSound.beep(); return }
        let model = controller.documentModel
        let toolbar = controller.toolbarState
        let viewport = model.session.view
        guard let image = model.session.displayed else { NSSound.beep(); return }
        let bytes = ImageExport.render(
            image,
            stretch: toolbar.stretch,
            vmin: Double(viewport.vmin),
            vmax: Double(viewport.vmax),
            colorMap: toolbar.colorMap,
            parameter: viewport.stretchParameter
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width, pixelsHigh: image.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: image.width * 4, bitsPerPixel: 32
        ), let dst = rep.bitmapData else { NSSound.beep(); return }
        memcpy(dst, bytes, bytes.count)
        let nsImage = NSImage(size: NSSize(width: image.width, height: image.height))
        nsImage.addRepresentation(rep)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: nsImage.size))
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: imageView)
        op.jobTitle = model.url.lastPathComponent
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        guard let window = controller.window else { NSSound.beep(); return }
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
