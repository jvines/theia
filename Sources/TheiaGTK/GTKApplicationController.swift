import CGtk4
import FITSCore
import Foundation
import TheiaKit
import TheiaRemote
import XPABridge

@MainActor final class GTKApplicationController {
    let application: UnsafeMutablePointer<GtkApplication>
    private let paths: [String]
    private let appPaths: AppPaths
    private let preferences: GTKPreferences
    private let workspace = Workspace()
    private let recentFiles: GTKRecentFiles
    private let catalogClient = CatalogClient(transport: CurlCatalogTransport())
    private let bridge = GTKMainLoopBridge()
    private lazy var scriptingServer = GTKScriptingServer(
        controller: self, runtimeDirectory: instanceRuntime?.directory
    )
    private lazy var xpaBridge = GTKXPACommandBridge(controller: self)
    private var xpaServer: XPAServer?
    private var xpaRuntime: GTKXPARuntime?
    private var instanceRuntime: GTKInstanceRuntime?
    private var windows: [UUID: GTKDocumentWindow] = [:]
    private var lightCurveWindow: GTKLightCurveWindow?
    private(set) var settingsWindow: GTKSettingsWindow?
    private(set) var infoWindows: [String: GTKInfoWindow] = [:]
    private var sessionPersistence: [UUID: GTKSessionPersistence] = [:]
    private(set) var staleDialogs: [UUID: GTKStaleSessionDialog] = [:]
    private(set) var welcomeWindow: UnsafeMutablePointer<GtkWindow>?
    private(set) var openDialog: GTKFileOpenDialog?
    private(set) var remoteDialog: GTKRemoteOpenDialog?
    private var remoteOpenTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var remoteTransferWindows: [UUID: GTKRemoteTransferWindow] = [:]
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
        recentFiles = GTKRecentFiles(paths: appPaths)
        application = gtk_application_new("cl.jvines.theia", GApplicationFlags(rawValue: 1 << 5))!
    }

    func run() -> Int32 {
        guard bridge.install() else { return 1 }
        do {
            instanceRuntime = try GTKInstanceRuntime(paths: appPaths)
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
        for task in remoteOpenTasks.values { task.cancel() }
        remoteOpenTasks.removeAll()
        for window in remoteTransferWindows.values { window.dismiss() }
        remoteTransferWindows.removeAll()
        xpaServer?.stop()
        xpaServer = nil
        xpaRuntime?.stop()
        xpaRuntime = nil
        scriptingServer.stop()
        instanceRuntime?.stop()
        instanceRuntime = nil
        bridge.remove()
        g_object_unref(UnsafeMutableRawPointer(application))
        return exitStatus == 0 ? status : exitStatus
    }

    private func startXPAServer() {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent(),
              let instanceRuntime else { return }
        let previous = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", previous.isEmpty ? directory.path : "\(directory.path):\(previous)", 1)
        let environment = ProcessInfo.processInfo.environment
        if environment["XPA_METHOD"] == "inet" {
            guard environment["XPA_NSINET"]?.hasPrefix("127.0.0.1:") == true else {
                fputs("Theia: inet XPA requires an explicit 127.0.0.1 XPA_NSINET\n", stderr)
                return
            }
        } else {
            do {
                xpaRuntime = try GTKXPARuntime(
                    instanceDirectory: instanceRuntime.directory, executableDirectory: directory
                )
            } catch {
                fputs("Theia: private XPA unavailable: \(error)\n", stderr)
                return
            }
        }
        let server = XPAServer(delegate: xpaBridge)
        server.start()
        xpaServer = server
    }

    func activate() {
        GTKTranslations.configure()
        var remoteURLs: [URL] = []
        for path in paths {
            if let url = URL(string: path), url.scheme?.lowercased() == "ssh" {
                remoteURLs.append(url)
                continue
            }
            do {
                _ = try open(path: path)
            } catch {
                fputs("Theia: cannot open \(path): \(error)\n", stderr)
                exitStatus = 1
            }
        }
        // The window a transfer's progress floats over must exist first; a
        // welcome window shown afterwards covers the progress window.
        if paths.isEmpty || (windows.isEmpty && !remoteURLs.isEmpty) {
            showWelcomeWindow()
        }
        for url in remoteURLs {
            do {
                try beginRemoteOpen(at: url)
            } catch {
                fputs("Theia: cannot open \(url.absoluteString): \(error)\n", stderr)
                exitStatus = 1
            }
        }
        if !paths.isEmpty && windows.isEmpty && remoteOpenTasks.isEmpty {
            g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
            return
        }
        if let warning = preferences.warningMessage {
            fputs("Theia: cannot read preferences: \(warning)\n", stderr)
        }
        if !preferences.hasSeenOnboarding {
            // Tied to the window it accompanies so tiling compositors float
            // it over that window instead of splitting the screen for it.
            if let parent = documentWindowsForScripting.first?.widget ?? welcomeWindow {
                GTKFirstFrame.after(parent) { [weak self] in
                    self?.showInfoWindow(.onboarding, over: parent)
                }
            } else {
                showInfoWindow(.onboarding)
            }
            do { try preferences.setHasSeenOnboarding(true) }
            catch { fputs("Theia: cannot save onboarding preference: \(error)\n", stderr) }
        }
    }

    @discardableResult func open(path: String) throws -> GTKDocumentWindow {
        try open(url: URL(fileURLWithPath: path))
    }

    @discardableResult func open(url: URL, remoteData: Data? = nil) throws -> GTKDocumentWindow {
        var newPersistence: GTKSessionPersistence?
        let opened = try workspace.open(url: url) { url in
            try loadSession(url: url, data: remoteData, stretch: preferences.defaultStretch,
                            colorMap: preferences.defaultColorMap, persistence: &newPersistence)
        }
        recentFiles.record(opened.session.url)
        refreshDocumentMenus()
        if let existing = windows[opened.session.id] {
            existing.present()
            return existing
        }
        return showWindow(for: opened.session, persistence: newPersistence)
    }

    /// Loads `url` (or `data` shown under it) into `window`'s frame, as DS9
    /// loads a file into the current frame: the document keeps the frame's
    /// number, stretch and colour map, and its window takes the old one's size.
    @discardableResult func replaceDocument(in window: GTKDocumentWindow, with url: URL,
                                            data: Data? = nil) throws -> GTKDocumentWindow {
        var newPersistence: GTKSessionPersistence?
        let replaced = window.session
        let opened = try workspace.open(url: url, replacing: replaced) { url in
            try loadSession(url: url, data: data, stretch: replaced.view.stretch,
                            colorMap: replaced.view.colorMap, persistence: &newPersistence)
        }
        if let existing = windows[opened.session.id] {
            existing.present()
            return existing
        }
        if opened.session.url.isFileURL { recentFiles.record(opened.session.url) }
        let oldWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.widget))
        let size = (gtk_widget_get_width(oldWidget), gtk_widget_get_height(oldWidget))
        let replacement = showWindow(for: opened.session, persistence: newPersistence,
                                     size: size.0 > 0 && size.1 > 0 ? size : nil)
        gtk_window_destroy(window.widget)
        return replacement
    }

    private func loadSession(url: URL, data: Data?, stretch: ImageStretch, colorMap: ColorMap,
                             persistence: inout GTKSessionPersistence?) throws -> DocumentSession {
        let fileData = try data ?? Data(contentsOf: url, options: .mappedIfSafe)
        let session = DocumentSession(
            url: url, file: try FITSFile(data: fileData),
            stretch: stretch, colorMap: colorMap,
            zscaleContrast: { [preferences] in preferences.zscaleContrast },
            catalogClient: catalogClient
        )
        persistence = GTKSessionPersistence(session: session, fileData: fileData, paths: appPaths)
        return session
    }

    private func showWindow(for session: DocumentSession, persistence newPersistence: GTKSessionPersistence?,
                            size: (Int32, Int32)? = nil) -> GTKDocumentWindow {
        if let newPersistence {
            sessionPersistence[session.id] = newPersistence
        }
        let window = GTKDocumentWindow(
            application: application, session: session,
            preferences: preferences,
            recentFiles: recentFiles,
            workspace: workspace,
            workspaceImageCount: { [weak self] in
                self?.windows.values.filter { $0.session.displayed != nil }.count ?? 1
            },
            onOpen: { [weak self] parent in self?.presentOpenDialog(parent: parent) },
            onOpenRemote: { [weak self] parent in
                self?.presentRemoteOpenDialog(parent: parent)
            },
            onOpenRecent: { [weak self] url in
                self?.openRecent(url)
            },
            onSettings: { [weak self] in self?.showSettingsWindow() },
            onDrop: { [weak self] paths in self?.openDropped(paths) },
            onWorkspaceCommand: { [weak self, weak session = session] command in
                guard let self, let session else { return }
                self.performWorkspaceCommand(command, from: session)
            },
            onWorkspaceToolAction: { [weak self] action, session in
                self?.performWorkspaceToolAction(action, from: session)
            },
            onFocus: { [weak self, weak session = session] in
                guard let self, let session else { return }
                self.workspace.focus(session)
            }
        ) { [weak self, weak session = session] in
            guard let self, let session else { return }
            self.staleDialogs.removeValue(forKey: session.id)?.dismiss()
            self.sessionPersistence.removeValue(forKey: session.id)?.close()
            self.windows.removeValue(forKey: session.id)
            self.workspace.unregister(session)
            self.refreshDocumentMenus()
        }
        windows[session.id] = window
        refreshDocumentMenus()
        if let size { gtk_window_set_default_size(window.widget, size.0, size.1) }
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
                    onClose: { [weak self, id = session.id] in
                        self?.staleDialogs.removeValue(forKey: id)
                    }
                )
                staleDialogs[session.id] = dialog
                dialog.present()
            }
        }
        if let welcomeWindow {
            self.welcomeWindow = nil
            gtk_window_destroy(welcomeWindow)
        }
        return window
    }

    func beginRemoteOpen(at url: URL) throws {
        let location = try RemoteFileLocation(url: url)
        let id = UUID()
        let progress = GTKRemoteTransferWindow(
            parent: documentWindowsForScripting.last?.widget ?? welcomeWindow,
            filename: url.lastPathComponent, host: url.host ?? "SSH"
        ) { [weak self] in self?.remoteOpenTasks[id]?.cancel() }
        remoteTransferWindows[id] = progress
        progress.present()
        remoteOpenTasks[id] = Task { [weak self] in
            defer {
                self?.remoteOpenTasks[id] = nil
                self?.remoteTransferWindows.removeValue(forKey: id)?.dismiss()
            }
            do {
                let data = try await SSHRemoteFileClient().readAsync(location)
                try Task.checkCancellation()
                guard let self else { return }
                _ = try self.open(url: url, remoteData: data)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                fputs("Theia: cannot open \(url.absoluteString): \(error)\n", stderr)
                self.showOpenError(error, url: url)
            }
        }
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
        let remoteButton = gtk_button_new_with_label("Open Remote…")!
        GTKButtonAction { [weak self] in
            guard let self, let parent = self.welcomeWindow else { return }
            self.presentRemoteOpenDialog(parent: parent)
        }.connect(to: remoteButton)
        gtk_box_append(box, remoteButton)
        let samples = BundledSamples.discover()
        if !samples.isEmpty {
            gtk_box_append(box, gtk_label_new("Samples"))
            for sample in samples {
                let button = gtk_button_new_with_label(sample.title)!
                GTKButtonAction { [weak self] in self?.openRecent(sample.url) }
                    .connect(to: button)
                gtk_box_append(box, button)
            }
        }
        let recent = recentFiles.urls(limit: 5)
        if !recent.isEmpty {
            gtk_box_append(box, gtk_label_new("Recent FITS files"))
            for url in recent {
                let title = url.isFileURL ? url.lastPathComponent
                    : "\(url.lastPathComponent) — \(url.host ?? "SSH")"
                let button = gtk_button_new_with_label(title)!
                GTKButtonAction { [weak self] in
                    self?.openRecent(url)
                }.connect(to: button)
                gtk_box_append(box, button)
            }
        }
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(OpaquePointer(scroll),
                                      UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)))
        gtk_window_set_child(window, scroll)
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

    private func openRecent(_ url: URL) {
        do {
            if url.isFileURL { _ = try open(path: url.path) }
            else { try beginRemoteOpen(at: url) }
        } catch {
            fputs("Theia: cannot open \(url.absoluteString): \(error)\n", stderr)
            showOpenError(error, url: url)
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

    private func showInfoWindow(_ kind: AppWindowKind,
                                over parent: UnsafeMutablePointer<GtkWindow>? = nil) {
        let key: String
        switch kind {
        case .about: key = "about"
        case .scriptingReference: key = "scripting"
        case .onboarding: key = "onboarding"
        case .welcome: showWelcomeWindow(); return
        }
        if let existing = infoWindows[key] { existing.present(); return }
        let window = GTKInfoWindow(application: application, kind: kind,
                                   scriptingPort: scriptingServer.port,
                                   scriptingTokenFile: instanceRuntime?.directory
                                       .appendingPathComponent("scripting-token")) { [weak self] in
            self?.infoWindows.removeValue(forKey: key)
        }
        infoWindows[key] = window
        if let parent { gtk_window_set_transient_for(window.widget, parent) }
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

    func presentRemoteOpenDialog(parent: UnsafeMutablePointer<GtkWindow>?) {
        if let remoteDialog {
            remoteDialog.present()
            return
        }
        let dialog = GTKRemoteOpenDialog(parent: parent) { [weak self] text in
            guard let self else { return }
            self.remoteDialog = nil
            guard let text else { return }
            guard let url = URL(string: text) else {
                self.showOpenError(RemoteWireError.invalidLocation,
                                   url: URL(fileURLWithPath: text))
                return
            }
            do { try self.beginRemoteOpen(at: url) }
            catch { self.showOpenError(error, url: url) }
        }
        remoteDialog = dialog
        dialog.present()
    }

    private func showOpenError(_ error: Error, url: URL) {
        let alert = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_window_new()!))
        gtk_window_set_title(alert, "Could not open \(url.lastPathComponent)")
        if let parent = documentWindowsForScripting.last?.widget ?? welcomeWindow {
            gtk_window_set_transient_for(alert, parent)
        }
        gtk_window_set_modal(alert, 1)
        gtk_window_set_default_size(alert, 400, 140)
        let box = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let content = UnsafeMutablePointer<GtkWidget>(OpaquePointer(box))
        gtk_widget_set_margin_top(content, 16)
        gtk_widget_set_margin_bottom(content, 16)
        gtk_widget_set_margin_start(content, 16)
        gtk_widget_set_margin_end(content, 16)
        let label = OpaquePointer(gtk_label_new(error.localizedDescription)!)
        gtk_label_set_wrap(label, 1)
        gtk_box_append(box, UnsafeMutablePointer<GtkWidget>(label))
        let close = gtk_button_new_with_label("Close")!
        GTKButtonAction { gtk_window_destroy(alert) }.connect(to: close)
        gtk_box_append(box, close)
        gtk_window_set_child(alert, content)
        gtk_window_present(alert)
    }
}
