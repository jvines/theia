import CGtk4
import FITSCore
import Foundation
import TheiaKit

@MainActor final class GTKApplicationController {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let paths: [String]
    private let workspace = Workspace()
    private let bridge = GTKMainLoopBridge()
    private var windows: [UUID: GTKDocumentWindow] = [:]
    private var exitStatus: Int32 = 0

    init(paths: [String]) {
        self.paths = paths
        application = gtk_application_new("cl.jvines.theia", GApplicationFlags(rawValue: 1 << 5))!
    }

    func run() -> Int32 {
        guard bridge.install() else { return 1 }
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
        bridge.remove()
        g_object_unref(UnsafeMutableRawPointer(application))
        return exitStatus == 0 ? status : exitStatus
    }

    private func activate() {
        for path in paths {
            do {
                let opened = try workspace.open(path: path) { url in
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return DocumentSession(url: url, file: try FITSFile(data: data))
                }
                if let existing = windows[opened.session.id] {
                    existing.present()
                } else {
                    let window = GTKDocumentWindow(
                        application: application, session: opened.session
                    ) { [weak self, weak session = opened.session] in
                        guard let self, let session else { return }
                        self.windows.removeValue(forKey: session.id)
                        self.workspace.unregister(session)
                    }
                    windows[opened.session.id] = window
                    window.present()
                }
            } catch {
                fputs("Theia: cannot open \(path): \(error)\n", stderr)
                exitStatus = 1
            }
        }
        if paths.isEmpty {
            let window = gtk_application_window_new(application)!
            gtk_window_set_title(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)), "Theia")
            gtk_window_set_default_size(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)), 640, 480)
            gtk_window_set_child(
                UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)),
                gtk_label_new("Open a FITS file from the command line")
            )
            gtk_window_present(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)))
        } else if windows.isEmpty {
            g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
        }
    }
}
