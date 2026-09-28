import CGtk4
import Foundation
import TheiaKit

@MainActor private final class NumberDialogAction {
    weak var dialog: GTKNumberDialog?

    init(_ dialog: GTKNumberDialog) { self.dialog = dialog }
    func accept() { dialog?.finish(accepted: true) }
    func cancel() { dialog?.finish(accepted: false) }
}

/// Nonblocking numeric input for shared command questions.
@MainActor final class GTKNumberDialog {
    let widget: UnsafeMutablePointer<GtkWindow>
    let entries: [OpaquePointer]
    let acceptButton: UnsafeMutablePointer<GtkWidget>
    private let onComplete: @MainActor (Answer) -> Void
    private var completed = false

    init(parent: UnsafeMutablePointer<GtkWindow>, prompt: String,
         fields: [String], defaults: [String],
         onComplete: @escaping @MainActor (Answer) -> Void) {
        precondition(fields.count == defaults.count)
        self.onComplete = onComplete
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_window_new()!))
        gtk_window_set_title(widget, "Extract Cube Slab")
        gtk_window_set_transient_for(widget, parent)
        gtk_window_set_modal(widget, 1)
        gtk_window_set_default_size(widget, 360, -1)

        let content = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let contentWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(content))
        gtk_widget_set_margin_top(contentWidget, 16)
        gtk_widget_set_margin_bottom(contentWidget, 16)
        gtk_widget_set_margin_start(contentWidget, 16)
        gtk_widget_set_margin_end(contentWidget, 16)
        let promptLabel = OpaquePointer(gtk_label_new(prompt)!)
        gtk_label_set_wrap(promptLabel, 1)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(promptLabel))

        var inputs: [OpaquePointer] = []
        for (name, initial) in zip(fields, defaults) {
            let row = UnsafeMutablePointer<GtkBox>(OpaquePointer(
                gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            ))
            gtk_box_append(row, gtk_label_new(name))
            let entry = OpaquePointer(gtk_entry_new()!)
            gtk_editable_set_text(entry, initial)
            gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(entry), 1)
            gtk_box_append(row, UnsafeMutablePointer<GtkWidget>(entry))
            gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(OpaquePointer(row)))
            inputs.append(entry)
        }
        entries = inputs

        let buttons = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_widget_set_halign(UnsafeMutablePointer<GtkWidget>(OpaquePointer(buttons)), GTK_ALIGN_END)
        let cancelButton = gtk_button_new_with_label("Cancel")!
        acceptButton = gtk_button_new_with_label("Extract")!
        gtk_box_append(buttons, cancelButton)
        gtk_box_append(buttons, acceptButton)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(OpaquePointer(buttons)))
        gtk_window_set_child(widget, contentWidget)

        let action = NumberDialogAction(self)
        GTKButtonAction { [weak action] in action?.cancel() }.connect(to: cancelButton)
        GTKButtonAction { [weak action] in action?.accept() }.connect(to: acceptButton)
        let context = Unmanaged.passRetained(action).toOpaque()
        let destroyed: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = {
            _, userData in
            guard let userData else { return }
            let action = Unmanaged<NumberDialogAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.cancel() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<NumberDialogAction>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(widget), "destroy",
            unsafeBitCast(destroyed, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
    }

    func present() { gtk_window_present(widget) }
    func dismiss() { finish(accepted: false) }

    fileprivate func finish(accepted: Bool) {
        guard !completed else { return }
        completed = true
        let answer: Answer = accepted
            ? .numbers(entries.map { Double(String(cString: gtk_editable_get_text($0))) ?? .nan })
            : .cancelled
        gtk_window_destroy(widget)
        onComplete(answer)
    }
}
