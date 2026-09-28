import CGtk4

/// Nonblocking restore choice for a FITS file whose header has changed.
@MainActor final class GTKStaleSessionDialog {
    let widget: UnsafeMutablePointer<GtkWindow>
    let restoreButton: UnsafeMutablePointer<GtkWidget>
    let discardButton: UnsafeMutablePointer<GtkWidget>
    private let onRestore: @MainActor () -> Void
    private let onDiscard: @MainActor () -> Void
    private let onClose: @MainActor () -> Void
    private var completed = false

    init(parent: UnsafeMutablePointer<GtkWindow>,
         onRestore: @escaping @MainActor () -> Void,
         onDiscard: @escaping @MainActor () -> Void,
         onClose: @escaping @MainActor () -> Void) {
        self.onRestore = onRestore
        self.onDiscard = onDiscard
        self.onClose = onClose
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_window_new()!))
        gtk_window_set_title(widget, "Saved session for changed FITS file")
        gtk_window_set_transient_for(widget, parent)
        gtk_window_set_modal(widget, 1)
        gtk_window_set_default_size(widget, 440, 170)
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 16)
        gtk_widget_set_margin_bottom(rootWidget, 16)
        gtk_widget_set_margin_start(rootWidget, 16)
        gtk_widget_set_margin_end(rootWidget, 16)
        let message = gtk_label_new(
            "This FITS file changed since an earlier session was saved. Restore its display " +
            "settings and regions, or discard the older session."
        )!
        gtk_label_set_wrap(OpaquePointer(message), 1)
        gtk_box_append(root, message)
        let buttons = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        discardButton = gtk_button_new_with_label("Discard old session")!
        restoreButton = gtk_button_new_with_label("Restore anyway")!
        GTKButtonAction { [weak self] in self?.finish(restore: false) }.connect(to: discardButton)
        GTKButtonAction { [weak self] in self?.finish(restore: true) }.connect(to: restoreButton)
        gtk_box_append(buttons, discardButton)
        gtk_box_append(buttons, restoreButton)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(buttons)))
        gtk_window_set_child(widget, rootWidget)
        let context = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let dialog = Unmanaged<GTKStaleSessionDialog>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { dialog.onClose() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKStaleSessionDialog>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }
    func dismiss() { gtk_window_destroy(widget) }

    private func finish(restore: Bool) {
        guard !completed else { return }
        completed = true
        if restore { onRestore() } else { onDiscard() }
        gtk_window_destroy(widget)
    }
}
