import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XPABridge

@MainActor final class GTKApplicationController {
    let application: UnsafeMutablePointer<GtkApplication>
    private let paths: [String]
    private let workspace = Workspace()
    private let catalogClient = CatalogClient(transport: CurlCatalogTransport())
    private let bridge = GTKMainLoopBridge()
    private lazy var scriptingServer = GTKScriptingServer(controller: self)
    private lazy var xpaBridge = GTKXPACommandBridge(controller: self)
    private var xpaServer: XPAServer?
    private var windows: [UUID: GTKDocumentWindow] = [:]
    private(set) var welcomeWindow: UnsafeMutablePointer<GtkWindow>?
    private(set) var openDialog: GTKFileOpenDialog?
    private var exitStatus: Int32 = 0

    var documentWindowCount: Int { windows.count }
    var documentWindowsForScripting: [GTKDocumentWindow] {
        windows.values.sorted { (workspace.id(of: $0.session) ?? -1) < (workspace.id(of: $1.session) ?? -1) }
    }

    func scriptingID(of window: GTKDocumentWindow) -> Int? { workspace.id(of: window.session) }
    func sessionForScripting(at id: Int) -> DocumentSession? { workspace.document(at: id) }
    func quitForScripting() {
        g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
    }
    func scheduleQuitForXPA() {
        Task { @MainActor [weak self] in self?.quitForScripting() }
    }

    init(paths: [String]) {
        self.paths = paths
        application = gtk_application_new("cl.jvines.theia", GApplicationFlags(rawValue: 1 << 5))!
    }

    func run() -> Int32 {
        guard bridge.install() else { return 1 }
        do {
            try scriptingServer.start()
        } catch {
            fputs("Theia: scripting server unavailable: \(error)\n", stderr)
        }
        startXPAServer()
        let context = Unmanaged.passRetained(self).toOpaque()
        let activate: @convention(c) (UnsafeMutablePointer<GtkApplication>?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let controller = Unmanaged<GTKApplicationController>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { controller.activate() }
        }
        let destroy: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKApplicationController>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(application), "activate",
            unsafeBitCast(activate, to: GCallback.self), context, destroy,
            GConnectFlags(rawValue: 0)
        )
        let status = g_application_run(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), 0, nil
        )
        xpaServer?.stop()
        xpaServer = nil
        scriptingServer.stop()
        bridge.remove()
        g_object_unref(UnsafeMutableRawPointer(application))
        return exitStatus == 0 ? status : exitStatus
    }

    private func startXPAServer() {
        if let directory = Bundle.main.executableURL?.deletingLastPathComponent().path {
            let previous = ProcessInfo.processInfo.environment["PATH"] ?? ""
            setenv("PATH", previous.isEmpty ? directory : "\(directory):\(previous)", 1)
        }
        let server = XPAServer(delegate: xpaBridge)
        server.start()
        xpaServer = server
    }

    private func activate() {
        for path in paths {
            do {
                _ = try open(path: path)
            } catch {
                fputs("Theia: cannot open \(path): \(error)\n", stderr)
                exitStatus = 1
            }
        }
        if paths.isEmpty {
            showWelcomeWindow()
        } else if windows.isEmpty {
            g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
        }
    }

    @discardableResult func open(path: String) throws -> GTKDocumentWindow {
        let opened = try workspace.open(path: path) { url in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return DocumentSession(url: url, file: try FITSFile(data: data),
                                   catalogClient: catalogClient)
        }
        if let existing = windows[opened.session.id] {
            existing.present()
            return existing
        }
        let window = GTKDocumentWindow(
            application: application, session: opened.session,
            onOpen: { [weak self] parent in self?.presentOpenDialog(parent: parent) }
        ) { [weak self, weak session = opened.session] in
            guard let self, let session else { return }
            self.windows.removeValue(forKey: session.id)
            self.workspace.unregister(session)
        }
        windows[opened.session.id] = window
        window.present()
        if let welcomeWindow {
            self.welcomeWindow = nil
            gtk_window_destroy(welcomeWindow)
        }
        return window
    }

    func showWelcomeWindow() {
        if let welcomeWindow {
            gtk_window_present(welcomeWindow)
            return
        }
        let window = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_application_window_new(application)!))
        welcomeWindow = window
        gtk_window_set_title(window, "Theia")
        gtk_window_set_default_size(window, 640, 480)
        let box = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!))
        gtk_widget_set_halign(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), GTK_ALIGN_CENTER)
        gtk_box_append(box, gtk_label_new("Open a FITS image"))
        let openButton = gtk_button_new_with_label("Open…")!
        GTKButtonAction { [weak self] in
            guard let self, let parent = self.welcomeWindow else { return }
            self.presentOpenDialog(parent: parent)
        }.connect(to: openButton)
        gtk_box_append(box, openButton)
        gtk_window_set_child(window, UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)))
        gtk_window_present(window)
    }

    func presentOpenDialog(parent: UnsafeMutablePointer<GtkWindow>?) {
        if let openDialog {
            openDialog.present()
            return
        }
        let dialog = GTKFileOpenDialog(parent: parent) { [weak self] path in
            guard let self else { return }
            self.openDialog = nil
            guard let path else { return }
            do {
                _ = try self.open(path: path)
            } catch {
                fputs("Theia: cannot open \(path): \(error)\n", stderr)
            }
        }
        openDialog = dialog
        dialog.present()
    }
}
