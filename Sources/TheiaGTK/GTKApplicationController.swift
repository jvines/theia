import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XPABridge

@MainActor final class GTKApplicationController {
    let application: UnsafeMutablePointer<GtkApplication>
    private let paths: [String]
    private let appPaths: AppPaths
    private let preferences: GTKPreferences
    private let workspace = Workspace()
    private let recentFiles = GTKRecentFiles()
    private let catalogClient = CatalogClient(transport: CurlCatalogTransport())
    private let bridge = GTKMainLoopBridge()
    private lazy var scriptingServer = GTKScriptingServer(controller: self)
    private lazy var xpaBridge = GTKXPACommandBridge(controller: self)
    private var xpaServer: XPAServer?
    private var windows: [UUID: GTKDocumentWindow] = [:]
    private var lightCurveWindow: GTKLightCurveWindow?
    private(set) var settingsWindow: GTKSettingsWindow?
    private(set) var infoWindows: [String: GTKInfoWindow] = [:]
    private var sessionPersistence: [UUID: GTKSessionPersistence] = [:]
    private(set) var staleDialogs: [UUID: GTKStaleSessionDialog] = [:]
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

    init(paths: [String], appPaths: AppPaths = AppPaths(platform: .linux)) {
        self.paths = paths
        self.appPaths = appPaths
        preferences = GTKPreferences(paths: appPaths)
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
            return
        }
        if let warning = preferences.warningMessage {
            fputs("Theia: cannot read preferences: \(warning)\n", stderr)
        }
        if !preferences.hasSeenOnboarding {
            showInfoWindow(.onboarding)
            do { try preferences.setHasSeenOnboarding(true) }
            catch { fputs("Theia: cannot save onboarding preference: \(error)\n", stderr) }
        }
    }

    @discardableResult func open(path: String) throws -> GTKDocumentWindow {
        var newPersistence: GTKSessionPersistence?
        let opened = try workspace.open(path: path) { url in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let session = DocumentSession(
                url: url, file: try FITSFile(data: data),
                stretch: preferences.defaultStretch,
                colorMap: preferences.defaultColorMap,
                zscaleContrast: { [preferences] in preferences.zscaleContrast },
                catalogClient: catalogClient
            )
            newPersistence = GTKSessionPersistence(session: session, fileData: data,
                                                   paths: appPaths)
            return session
        }
        recentFiles.record(opened.session.url)
        refreshDocumentMenus()
        if let existing = windows[opened.session.id] {
            existing.present()
            return existing
        }
        if let newPersistence {
            sessionPersistence[opened.session.id] = newPersistence
        }
        let window = GTKDocumentWindow(
            application: application, session: opened.session,
            preferences: preferences,
            recentFiles: recentFiles,
            workspace: workspace,
            workspaceImageCount: { [weak self] in
                self?.windows.values.filter { $0.session.displayed != nil }.count ?? 1
            },
            onOpen: { [weak self] parent in self?.presentOpenDialog(parent: parent) },
            onOpenRecent: { [weak self] url in
                do { _ = try self?.open(path: url.path) }
                catch { fputs("Theia: cannot open \(url.path): \(error)\n", stderr) }
            },
            onSettings: { [weak self] in self?.showSettingsWindow() },
            onDrop: { [weak self] paths in self?.openDropped(paths) },
            onWorkspaceCommand: { [weak self, weak session = opened.session] command in
                guard let self, let session else { return }
                self.performWorkspaceCommand(command, from: session)
            },
            onWorkspaceToolAction: { [weak self] action, session in
                self?.performWorkspaceToolAction(action, from: session)
            },
            onFocus: { [weak self, weak session = opened.session] in
                guard let self, let session else { return }
                self.workspace.focus(session)
            }
        ) { [weak self, weak session = opened.session] in
            guard let self, let session else { return }
            self.staleDialogs.removeValue(forKey: session.id)?.dismiss()
            self.sessionPersistence.removeValue(forKey: session.id)?.close()
            self.windows.removeValue(forKey: session.id)
            self.workspace.unregister(session)
            self.refreshDocumentMenus()
        }
        windows[opened.session.id] = window
        refreshDocumentMenus()
        window.present()
        if let newPersistence {
            newPersistence.onWarning = { [weak window] message in
                window?.handleOutcome(CommandOutcome(effects: [
                    .alert(title: "Session not saved", message: message, style: .warning)
                ]))
            }
            newPersistence.start()
            if let warning = newPersistence.warningMessage {
                newPersistence.onWarning?(warning)
            }
            if newPersistence.staleState != nil {
                let dialog = GTKStaleSessionDialog(
                    parent: window.widget,
                    onRestore: { [weak newPersistence] in newPersistence?.restoreStale() },
                    onDiscard: { [weak newPersistence] in newPersistence?.discardStale() },
                    onClose: { [weak self, id = opened.session.id] in
                        self?.staleDialogs.removeValue(forKey: id)
                    }
                )
                staleDialogs[opened.session.id] = dialog
                dialog.present()
            }
        }
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
        let recent = recentFiles.urls(limit: 5)
        if !recent.isEmpty {
            gtk_box_append(box, gtk_label_new("Recent FITS files"))
            for url in recent {
                let button = gtk_button_new_with_label(url.lastPathComponent)!
                GTKButtonAction { [weak self] in
                    do { _ = try self?.open(path: url.path) }
                    catch { fputs("Theia: cannot open \(url.path): \(error)\n", stderr) }
                }.connect(to: button)
                gtk_box_append(box, button)
            }
        }
        gtk_window_set_child(window, UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)))
        GTKFileDropTarget.install(on: UnsafeMutablePointer<GtkWidget>(OpaquePointer(window))) {
            [weak self] paths in self?.openDropped(paths)
        }
        gtk_window_present(window)
    }

    private func openDropped(_ paths: [String]) {
        for path in paths {
            do { _ = try open(path: path) }
            catch { fputs("Theia: cannot open \(path): \(error)\n", stderr) }
        }
    }

    private func refreshDocumentMenus() {
        for window in windows.values { window.refreshRecentMenu() }
    }

    private func performWorkspaceToolAction(_ action: ToolMenuAction,
                                            from session: DocumentSession) {
        guard let id = workspace.id(of: session) else { return }
        let command: WorkspaceCommand
        switch action {
        case .stack(let mode): command = .stack(documentID: id, mode: mode)
        case .lightCurve: command = .lightCurve(documentID: id)
        default: return
        }
        performWorkspaceCommand(command, from: session)
    }

    private func performWorkspaceCommand(_ command: WorkspaceCommand,
                                         from session: DocumentSession) {
        let outcome = workspace.perform(command, origin: .user)
        let source = windows[session.id]
        if let failure = outcome.failure, outcome.effects.isEmpty {
            source?.handleOutcome(CommandOutcome(failure: failure))
        }
        for effect in outcome.effects {
            switch effect {
            case .showAppWindow(.welcome): showWelcomeWindow()
            case .showAppWindow(let kind): showInfoWindow(kind)
            case .openURL(let url):
                GTKURLOpener.open(url, parent: source?.widget) { message in
                    fputs("Theia: could not open URL: \(message)\n", stderr)
                }
            case .openLightCurve(let model):
                if let lightCurveWindow {
                    lightCurveWindow.update(model)
                } else {
                    let window = GTKLightCurveWindow(
                        application: application, model: model, sourceSession: session
                    ) { [weak self] in self?.lightCurveWindow = nil }
                    lightCurveWindow = window
                    window.present()
                }
            case .quit: quitForScripting()
            case .tileWindows:
                for window in documentWindowsForScripting { window.present() }
            default:
                source?.handleOutcome(CommandOutcome(effects: [effect]))
            }
        }
        refreshDocumentMenus()
    }

    private func showInfoWindow(_ kind: AppWindowKind) {
        let key: String
        switch kind {
        case .about: key = "about"
        case .scriptingReference: key = "scripting"
        case .onboarding: key = "onboarding"
        case .welcome: showWelcomeWindow(); return
        }
        if let existing = infoWindows[key] { existing.present(); return }
        let window = GTKInfoWindow(application: application, kind: kind,
                                   scriptingPort: scriptingServer.port) { [weak self] in
            self?.infoWindows.removeValue(forKey: key)
        }
        infoWindows[key] = window
        window.present()
    }

    private func showSettingsWindow() {
        if let settingsWindow { settingsWindow.present(); return }
        let window = GTKSettingsWindow(application: application, preferences: preferences) {
            [weak self] in self?.settingsWindow = nil
        }
        settingsWindow = window
        window.present()
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
