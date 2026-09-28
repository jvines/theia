import CGtk4
import Foundation

@MainActor private final class RemoteDialogAction {
    weak var dialog: GTKRemoteOpenDialog?

    init(_ dialog: GTKRemoteOpenDialog) { self.dialog = dialog }
    func accept() { dialog?.finish(accepted: true) }
    func cancel() { dialog?.finish(accepted: false) }
}

/// Collects an SSH FITS location without blocking GTK's main loop.
@MainActor final class GTKRemoteOpenDialog {
    let widget: UnsafeMutablePointer<GtkWindow>
    let entry: OpaquePointer
    let acceptButton: UnsafeMutablePointer<GtkWidget>
    private let onComplete: @MainActor (String?) -> Void
    private var completed = false

    init(parent: UnsafeMutablePointer<GtkWindow>?,
         onComplete: @escaping @MainActor (String?) -> Void) {
        self.onComplete = onComplete
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_window_new()!))
        gtk_window_set_title(widget, "Open Remote FITS File")
        if let parent { gtk_window_set_transient_for(widget, parent) }
        gtk_window_set_modal(widget, 1)
        gtk_window_set_default_size(widget, 480, -1)

        let box = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let content = UnsafeMutablePointer<GtkWidget>(OpaquePointer(box))
        gtk_widget_set_margin_top(content, 16)
        gtk_widget_set_margin_bottom(content, 16)
        gtk_widget_set_margin_start(content, 16)
        gtk_widget_set_margin_end(content, 16)
        gtk_box_append(box, gtk_label_new("SSH URL of a FITS file on the cluster"))
        entry = OpaquePointer(gtk_entry_new()!)
        gtk_entry_set_placeholder_text(UnsafeMutablePointer<GtkEntry>(entry),
                                       "ssh://user@host/absolute/path/image.fits")
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(entry), 1)
        gtk_box_append(box, UnsafeMutablePointer<GtkWidget>(entry))

        let buttons = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_widget_set_halign(UnsafeMutablePointer<GtkWidget>(OpaquePointer(buttons)), GTK_ALIGN_END)
        let cancelButton = gtk_button_new_with_label("Cancel")!
        acceptButton = gtk_button_new_with_label("Open")!
        gtk_box_append(buttons, cancelButton)
        gtk_box_append(buttons, acceptButton)
        gtk_box_append(box, UnsafeMutablePointer<GtkWidget>(OpaquePointer(buttons)))
        gtk_window_set_child(widget, content)

        let action = RemoteDialogAction(self)
        GTKButtonAction { [weak action] in action?.cancel() }.connect(to: cancelButton)
        GTKButtonAction { [weak action] in action?.accept() }.connect(to: acceptButton)
        let context = Unmanaged.passRetained(action).toOpaque()
        let destroyed: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = {
            _, userData in
            guard let userData else { return }
            let action = Unmanaged<RemoteDialogAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.cancel() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<RemoteDialogAction>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }

    fileprivate func finish(accepted: Bool) {
        guard !completed else { return }
        completed = true
        let value = accepted
            ? String(cString: gtk_editable_get_text(entry))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        gtk_window_destroy(widget)
        onComplete(value)
    }
}
