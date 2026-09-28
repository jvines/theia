import CGtk4
import Foundation

@MainActor private final class FileDialogResponseAction {
    weak var dialog: GTKFileOpenDialog?

    init(dialog: GTKFileOpenDialog) { self.dialog = dialog }

    func invoke(response: gint) { dialog?.handleResponse(response) }
}

@MainActor final class GTKFileOpenDialog {
    let native: UnsafeMutablePointer<GtkNativeDialog>
    let chooser: OpaquePointer
    private let onComplete: @MainActor (String?) -> Void
    private var completed = false

    init(parent: UnsafeMutablePointer<GtkWindow>?,
         onComplete: @escaping @MainActor (String?) -> Void) {
        self.onComplete = onComplete
        let fileDialog = gtk_file_chooser_native_new(
            "Open FITS File", parent, GTK_FILE_CHOOSER_ACTION_OPEN, "Open", "Cancel"
        )!
        native = UnsafeMutablePointer<GtkNativeDialog>(fileDialog)
        chooser = fileDialog
        let filter = gtk_file_filter_new()!
        gtk_file_filter_set_name(filter, "FITS images")
        for pattern in ["*.fits", "*.fit", "*.fts", "*.fz", "*.FITS", "*.FIT", "*.FTS", "*.FZ"] {
            gtk_file_filter_add_pattern(filter, pattern)
        }
        gtk_file_chooser_add_filter(chooser, filter)
        let allFiles = gtk_file_filter_new()!
        gtk_file_filter_set_name(allFiles, "All files")
        gtk_file_filter_add_pattern(allFiles, "*")
        gtk_file_chooser_add_filter(chooser, allFiles)

        let context = Unmanaged.passRetained(FileDialogResponseAction(dialog: self)).toOpaque()
        let callback: @convention(c) (UnsafeMutablePointer<GtkNativeDialog>?, gint, gpointer?) -> Void = {
            _, response, userData in
            guard let userData else { return }
            let action = Unmanaged<FileDialogResponseAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.invoke(response: response) }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<FileDialogResponseAction>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(native), "response",
            unsafeBitCast(callback, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(native)) }

    func present() { gtk_native_dialog_show(native) }

    fileprivate func handleResponse(_ response: gint) {
        guard !completed else { return }
        completed = true
        var selectedPath: String?
        if response == GTK_RESPONSE_ACCEPT.rawValue, let file = gtk_file_chooser_get_file(chooser) {
            if let path = g_file_get_path(file) {
                selectedPath = String(cString: path)
                g_free(path)
            }
            g_object_unref(UnsafeMutableRawPointer(file))
        }
        gtk_native_dialog_hide(native)
        onComplete(selectedPath)
    }
}
