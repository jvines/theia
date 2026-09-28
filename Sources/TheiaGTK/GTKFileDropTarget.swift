import CGtk4

@MainActor private final class FileDropAction {
    let open: @MainActor ([String]) -> Void
    init(open: @escaping @MainActor ([String]) -> Void) { self.open = open }
}

/// Accepts the file-list format sent by GTK file managers and uses the same
/// document-opening path as argv and the file chooser.
@MainActor enum GTKFileDropTarget {
    static func install(on widget: UnsafeMutablePointer<GtkWidget>,
                        open: @escaping @MainActor ([String]) -> Void) {
        let target = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)!
        let context = Unmanaged.passRetained(FileDropAction(open: open)).toOpaque()
        let dropped: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?,
                                      gdouble, gdouble, gpointer?) -> gboolean = {
            _, value, _, _, userData in
            guard let value, let userData else { return 0 }
            let paths = GTKFileDropTarget.paths(from: value)
            guard !paths.isEmpty else { return 0 }
            let action = Unmanaged<FileDropAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.open(paths) }
            return 1
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<FileDropAction>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(target), "drop",
                              unsafeBitCast(dropped, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(widget, target)
    }

    static func paths(from value: UnsafePointer<GValue>) -> [String] {
        guard let raw = g_value_get_boxed(value) else { return [] }
        var paths: [String] = []
        var node = gdk_file_list_get_files(OpaquePointer(raw))
        while let current = node {
            if let file = current.pointee.data,
               let path = g_file_get_path(OpaquePointer(file)) {
                paths.append(String(cString: path))
                g_free(path)
            }
            node = current.pointee.next
        }
        return paths
    }
}
