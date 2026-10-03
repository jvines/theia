import CGtk4
import Foundation
import Glibc

/// Keeps a running Theia on the palette the desktop writes into the user
/// stylesheet. GTK reads $XDG_CONFIG_HOME/gtk-4.0/gtk.css once, at startup,
/// and afterwards re-parses its copy from memory, so a palette switch
/// otherwise reaches a running app only as a light/dark flip in the colours
/// the file held at launch. Theia watches the file, and the file it links to,
/// since a desktop may link it and replace the target by rename, and reloads
/// GTK's own copy in place on each change. Where GTK's copy cannot be found,
/// each change loads into a Theia provider above it instead, through which a
/// rule only the launch palette had still shows.
@MainActor final class GTKUserStylesheet {
    let path: String
    /// The stylesheet as it read at start, kept parsed under the same media
    /// features as GTK's copy until it has identified that copy.
    private var launchCopy: UnsafeMutablePointer<GtkCssProvider>?
    private var gtkProvider: UnsafeMutablePointer<GtkCssProvider>?
    private var overlay: UnsafeMutablePointer<GtkCssProvider>?
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
        launchCopy = makeLaunchCopy()
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
        if let overlay, let display = gdk_display_get_default() {
            gtk_style_context_remove_provider_for_display(display, OpaquePointer(overlay))
        }
        for provider in [launchCopy, gtkProvider, overlay].compactMap({ $0 }) {
            g_object_unref(UnsafeMutableRawPointer(provider))
        }
        launchCopy = nil
        gtkProvider = nil
        overlay = nil
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
        if let launchCopy {
            self.launchCopy = nil
            gtkProvider = findGTKProvider(matching: launchCopy)
            g_object_unref(UnsafeMutableRawPointer(launchCopy))
        }
        guard let provider = gtkProvider ?? overlay ?? installOverlay() else { return }
        // GTK loads the file at startup only when it is a regular file,
        // following links; a stylesheet removed since then styles nothing.
        if g_file_test(path, G_FILE_TEST_IS_REGULAR) != 0 {
            gtk_css_provider_load_from_path(provider, path)
        } else {
            gtk_css_provider_load_from_string(provider, "")
        }
    }

    /// Without a file at launch GTK's copy is empty, and an overlay is exact.
    private func makeLaunchCopy() -> UnsafeMutablePointer<GtkCssProvider>? {
        guard g_file_test(path, G_FILE_TEST_IS_REGULAR) != 0,
              let display = gdk_display_get_default(),
              let settings = gtk_settings_get_for_display(display) else { return nil }
        let copy = gtk_css_provider_new()!
        // GTK has already reported this file's mistakes; a handler keeps the
        // copy from reporting them again.
        let quiet: @convention(c) (gpointer?, gpointer?, gpointer?, gpointer?) -> Void = { _, _, _, _ in }
        g_signal_connect_data(UnsafeMutableRawPointer(copy), "parsing-error",
                              unsafeBitCast(quiet, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        Self.bindMediaFeatures(of: settings, to: copy)
        gtk_css_provider_load_from_path(copy, path)
        return copy
    }

    /// GTK keeps no handle on the provider it read the stylesheet into. That
    /// provider re-parses itself whenever a media feature changes and tells
    /// the style system so: flipping reduced motion and back makes it show
    /// itself, and the one whose rules match the launch copy is it.
    private func findGTKProvider(
        matching launchCopy: UnsafeMutablePointer<GtkCssProvider>
    ) -> UnsafeMutablePointer<GtkCssProvider>? {
        let setting = "gtk-interface-reduced-motion"
        guard let display = gdk_display_get_default(),
              let settings = gtk_settings_get_for_display(display),
              Self.hasProperty(gtk_settings_get_type(), setting) else { return nil }
        let signal = g_signal_lookup("gtk-private-changed", gtk_style_provider_get_type())
        guard signal != 0 else { return nil }
        let announced = AnnouncedProviders()
        let hook: GSignalEmissionHook = { _, count, values, data in
            guard count > 0, let values, let data, let object = g_value_get_object(values) else { return 1 }
            Unmanaged<AnnouncedProviders>.fromOpaque(data).takeUnretainedValue().objects.append(object)
            return 1
        }
        let hookID = g_signal_add_emission_hook(
            signal, 0, hook, Unmanaged.passRetained(announced).toOpaque(),
            { data in
                guard let data else { return }
                Unmanaged<AnnouncedProviders>.fromOpaque(data).release()
            }
        )
        Self.flip(setting, of: settings)
        g_signal_remove_emission_hook(signal, hookID)

        let expected = Self.rules(of: launchCopy)
        let cssProvider = gtk_css_provider_get_type()
        for object in announced.objects where object != UnsafeMutableRawPointer(launchCopy) {
            guard g_type_check_instance_is_a(object.assumingMemoryBound(to: GTypeInstance.self), cssProvider) != 0
            else { continue }
            let candidate = object.assumingMemoryBound(to: GtkCssProvider.self)
            if Self.rules(of: candidate) == expected {
                g_object_ref(object)
                return candidate
            }
        }
        return nil
    }

    /// Moves a two-valued setting off its value and back without pinning it
    /// to the app. A value the app sets stops following the desktop, so the
    /// setting is reset, read back from the desktop and announced again.
    private static func flip(_ setting: String, of settings: OpaquePointer) {
        let object = UnsafeMutablePointer<GObject>(settings)
        guard let typeClass = g_type_class_ref(gtk_settings_get_type()) else { return }
        defer { g_type_class_unref(typeClass) }
        guard let spec = g_object_class_find_property(
            typeClass.assumingMemoryBound(to: GObjectClass.self), setting
        ) else { return }
        var value = GValue()
        g_value_init(&value, spec.pointee.value_type)
        defer { g_value_unset(&value) }
        g_object_get_property(object, setting, &value)
        let original = g_value_get_enum(&value)
        g_value_set_enum(&value, original == 0 ? 1 : 0)
        g_object_set_property(object, setting, &value)
        gtk_settings_reset_property(settings, setting)
        g_object_get_property(object, setting, &value)
        g_object_notify(object, setting)
        if g_value_get_enum(&value) != original {
            g_value_set_enum(&value, original)
            g_object_set_property(object, setting, &value)
        }
    }

    private func installOverlay() -> UnsafeMutablePointer<GtkCssProvider>? {
        guard let display = gdk_display_get_default(),
              let settings = gtk_settings_get_for_display(display) else { return nil }
        let created = gtk_css_provider_new()!
        Self.bindMediaFeatures(of: settings, to: created)
        gtk_style_context_add_provider_for_display(display, OpaquePointer(created),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_USER))
        overlay = created
        return created
    }

    /// As GTK does for its own copy: @media (prefers-color-scheme) and the
    /// other media features follow the desktop's settings. GTK older than
    /// 4.20 has none of them.
    private static func bindMediaFeatures(of settings: OpaquePointer,
                                          to provider: UnsafeMutablePointer<GtkCssProvider>) {
        for (setting, feature) in [("gtk-interface-color-scheme", "prefers-color-scheme"),
                                   ("gtk-interface-contrast", "prefers-contrast"),
                                   ("gtk-interface-reduced-motion", "prefers-reduced-motion")]
        where hasProperty(gtk_settings_get_type(), setting)
            && hasProperty(gtk_css_provider_get_type(), feature) {
            g_object_bind_property(UnsafeMutableRawPointer(settings), setting,
                                   UnsafeMutableRawPointer(provider), feature, G_BINDING_SYNC_CREATE)
        }
    }

    private static func rules(of provider: UnsafeMutablePointer<GtkCssProvider>) -> String {
        guard let text = gtk_css_provider_to_string(provider) else { return "" }
        defer { g_free(text) }
        return String(cString: text)
    }

    private static func hasProperty(_ type: GType, _ name: String) -> Bool {
        guard let typeClass = g_type_class_ref(type) else { return false }
        defer { g_type_class_unref(typeClass) }
        return g_object_class_find_property(typeClass.assumingMemoryBound(to: GObjectClass.self), name) != nil
    }
}

/// Providers that re-parsed while GTK's copy was being looked for.
private final class AnnouncedProviders {
    var objects: [UnsafeMutableRawPointer] = []
}
