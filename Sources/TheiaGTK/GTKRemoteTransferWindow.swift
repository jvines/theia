import CGtk4

/// A cancellable status window shown while SSH is fetching a remote FITS file.
@MainActor final class GTKRemoteTransferWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let cancelButton: UnsafeMutablePointer<GtkWidget>
    private let onCancel: @MainActor () -> Void
    private var finished = false
    var isFinished: Bool { finished }

    init(parent: UnsafeMutablePointer<GtkWindow>?, filename: String, host: String,
         onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_window_new()!))
        gtk_window_set_title(widget, "Opening remote FITS file")
        if let parent { gtk_window_set_transient_for(widget, parent) }
        gtk_window_set_modal(widget, 1)
        gtk_window_set_default_size(widget, 400, 120)
        let box = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let content = UnsafeMutablePointer<GtkWidget>(OpaquePointer(box))
        gtk_widget_set_margin_top(content, 16)
        gtk_widget_set_margin_bottom(content, 16)
        gtk_widget_set_margin_start(content, 16)
        gtk_widget_set_margin_end(content, 16)
        let row = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        ))
        let spinner = gtk_spinner_new()!
        gtk_spinner_start(OpaquePointer(spinner))
        gtk_box_append(row, spinner)
        let label = gtk_label_new("Fetching \(filename) from \(host)…")!
        gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_append(row, label)
        gtk_box_append(box, UnsafeMutablePointer<GtkWidget>(OpaquePointer(row)))
        cancelButton = gtk_button_new_with_label("Cancel")!
        gtk_widget_set_halign(cancelButton, GTK_ALIGN_END)
        gtk_box_append(box, cancelButton)
        gtk_window_set_child(widget, content)

        GTKButtonAction { [weak self] in self?.cancel() }.connect(to: cancelButton)
        let context = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = {
            _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKRemoteTransferWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.cancel() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKRemoteTransferWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }

    func dismiss() {
        guard !finished else { return }
        finished = true
        gtk_window_destroy(widget)
    }

    fileprivate func cancel() {
        guard !finished else { return }
        finished = true
        gtk_window_destroy(widget)
        onCancel()
    }
}
