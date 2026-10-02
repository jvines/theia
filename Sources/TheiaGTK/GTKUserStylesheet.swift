import CGtk4
import Foundation
import Glibc

/// Keeps a running Theia on the palette the desktop writes into the user
/// stylesheet. GTK reads $XDG_CONFIG_HOME/gtk-4.0/gtk.css once, at startup, so
/// a palette switch otherwise reaches a running app only as a light/dark flip
/// in the colours the file held at launch. Theia watches the file, and the
/// file it links to, since a desktop may link it and replace the target by
/// rename, and loads each change into its own provider at user priority,
/// which GTK consults before its startup copy.
@MainActor final class GTKUserStylesheet {
    let path: String
    private var provider: UnsafeMutablePointer<GtkCssProvider>?
    private var pathMonitor: UnsafeMutablePointer<GFileMonitor>?
    private var targetMonitor: UnsafeMutablePointer<GFileMonitor>?
    private var target: String?
    private var reloadSourceID: guint = 0

    init(path: String = GTKUserStylesheet.defaultPath) {
        self.path = path
    }

    /// The file GTK loads as the user stylesheet.
    nonisolated static var defaultPath: String {
        URL(fileURLWithPath: String(cString: g_get_user_config_dir()))
            .appendingPathComponent("gtk-4.0/gtk.css").path
    }

    func start() {
        guard pathMonitor == nil else { return }
        pathMonitor = monitor(path)
        followTarget()
    }

    func stop() {
        if reloadSourceID != 0 {
            g_source_remove(reloadSourceID)
            reloadSourceID = 0
        }
        for monitor in [pathMonitor, targetMonitor].compactMap({ $0 }) { release(monitor) }
        pathMonitor = nil
        targetMonitor = nil
        target = nil
        if let provider {
            if let display = gdk_display_get_default() {
                gtk_style_context_remove_provider_for_display(display, OpaquePointer(provider))
            }
            g_object_unref(UnsafeMutableRawPointer(provider))
            self.provider = nil
        }
    }

    /// Watches what the link points to now; a desktop may repoint it.
    private func followTarget() {
        let resolved = realpath(path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let next = resolved == path ? nil : resolved
        guard next != target else { return }
        if let targetMonitor { release(targetMonitor) }
        targetMonitor = next.flatMap(monitor)
        target = next
    }

    private func monitor(_ file: String) -> UnsafeMutablePointer<GFileMonitor>? {
        let handle = g_file_new_for_path(file)
        defer { g_object_unref(UnsafeMutableRawPointer(handle)) }
        guard let monitor = g_file_monitor_file(handle, G_FILE_MONITOR_NONE, nil, nil) else { return nil }
        let context = Unmanaged.passRetained(self).toOpaque()
        let changed: @convention(c) (
            UnsafeMutablePointer<GFileMonitor>?, OpaquePointer?, OpaquePointer?, GFileMonitorEvent, gpointer?
        ) -> Void = { _, _, _, event, userData in
            guard let userData else { return }
            let stylesheet = Unmanaged<GTKUserStylesheet>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { stylesheet.fileChanged(event) }
        }
        let destroy: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKUserStylesheet>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(monitor), "changed",
            unsafeBitCast(changed, to: GCallback.self), context, destroy,
            GConnectFlags(rawValue: 0)
        )
        return monitor
    }

    private func release(_ monitor: UnsafeMutablePointer<GFileMonitor>) {
        _ = g_file_monitor_cancel(monitor)
        g_object_unref(UnsafeMutableRawPointer(monitor))
    }

    private func fileChanged(_ event: GFileMonitorEvent) {
        switch event {
        case G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED, G_FILE_MONITOR_EVENT_PRE_UNMOUNT,
             G_FILE_MONITOR_EVENT_UNMOUNTED:
            return
        default:
            break
        }
        // One reload for the burst of events a single write or rename makes.
        guard reloadSourceID == 0 else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        reloadSourceID = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { userData in
            guard let userData else { return 0 }
            let stylesheet = Unmanaged<GTKUserStylesheet>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                stylesheet.reloadSourceID = 0
                stylesheet.reload()
            }
            return 0
        }, context, { userData in
            guard let userData else { return }
            Unmanaged<GTKUserStylesheet>.fromOpaque(userData).release()
        })
    }

    private func reload() {
        followTarget()
        guard let provider = provider ?? installProvider() else { return }
        // GTK loads the file at startup only when it is a regular file,
        // following links; a stylesheet removed since then styles nothing.
        if g_file_test(path, G_FILE_TEST_IS_REGULAR) != 0 {
            gtk_css_provider_load_from_path(provider, path)
        } else {
            gtk_css_provider_load_from_string(provider, "")
        }
    }

    private func installProvider() -> UnsafeMutablePointer<GtkCssProvider>? {
        guard let display = gdk_display_get_default(),
              let settings = gtk_settings_get_for_display(display) else { return nil }
        let created = gtk_css_provider_new()!
        // As GTK does for its own copy: @media (prefers-color-scheme) and the
        // other media features follow the desktop's settings. GTK older than
        // 4.20 has none of them.
        for (setting, feature) in [("gtk-interface-color-scheme", "prefers-color-scheme"),
                                   ("gtk-interface-contrast", "prefers-contrast"),
                                   ("gtk-interface-reduced-motion", "prefers-reduced-motion")]
        where Self.hasProperty(gtk_settings_get_type(), setting)
            && Self.hasProperty(gtk_css_provider_get_type(), feature) {
            g_object_bind_property(UnsafeMutableRawPointer(settings), setting,
                                   UnsafeMutableRawPointer(created), feature, G_BINDING_SYNC_CREATE)
        }
        gtk_style_context_add_provider_for_display(display, OpaquePointer(created),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_USER))
        provider = created
        return created
    }

    private static func hasProperty(_ type: GType, _ name: String) -> Bool {
        guard let typeClass = g_type_class_ref(type) else { return false }
        defer { g_type_class_unref(typeClass) }
        return g_object_class_find_property(typeClass.assumingMemoryBound(to: GObjectClass.self), name) != nil
    }
}
