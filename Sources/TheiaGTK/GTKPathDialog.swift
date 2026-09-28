import CGtk4
import Foundation
import TheiaKit

@MainActor private final class PathDialogResponseAction {
    weak var dialog: GTKPathDialog?
    init(dialog: GTKPathDialog) { self.dialog = dialog }
    func invoke(response: gint) { dialog?.handleResponse(response) }
}

/// Nonblocking native chooser for shared command questions.
@MainActor final class GTKPathDialog {
    let native: UnsafeMutablePointer<GtkNativeDialog>
    let chooser: OpaquePointer
    private let multiple: Bool
    private let onComplete: @MainActor (Answer) -> Void
    private var completed = false

    init(parent: UnsafeMutablePointer<GtkWindow>, question: Question,
         onComplete: @escaping @MainActor (Answer) -> Void) {
        self.onComplete = onComplete
        let title: String
        let action: GtkFileChooserAction
        let accept: String
        let types: [String]
        switch question {
        case .savePath(let name, let extensions):
            title = extensions.contains("reg") ? "Save Regions" : "Save File"
            action = GTK_FILE_CHOOSER_ACTION_SAVE
            accept = "Save"
            types = extensions
            multiple = false
            let dialog = gtk_file_chooser_native_new(title, parent, action, accept, "Cancel")!
            native = UnsafeMutablePointer<GtkNativeDialog>(dialog)
            chooser = dialog
            gtk_file_chooser_set_current_name(chooser, name)
        case .openPath(let extensions, let allowsMultiple):
            title = extensions.contains("reg") || extensions.contains("public.plain-text")
                ? "Load Regions" : "Open File"
            action = GTK_FILE_CHOOSER_ACTION_OPEN
            accept = "Open"
            types = extensions
            multiple = allowsMultiple
            let dialog = gtk_file_chooser_native_new(title, parent, action, accept, "Cancel")!
            native = UnsafeMutablePointer<GtkNativeDialog>(dialog)
            chooser = dialog
            gtk_file_chooser_set_select_multiple(chooser, allowsMultiple ? 1 : 0)
        case .numbers:
            preconditionFailure("Numeric questions use a separate GTK dialog")
        }
        let filter = gtk_file_filter_new()!
        gtk_file_filter_set_name(filter, "Supported files")
        let extensions = types.filter { !$0.contains(".") }
        for ext in extensions {
            gtk_file_filter_add_pattern(filter, "*.\(ext)")
            gtk_file_filter_add_pattern(filter, "*.\(ext.uppercased())")
        }
        if !extensions.isEmpty { gtk_file_chooser_add_filter(chooser, filter) }
        else { g_object_unref(UnsafeMutableRawPointer(filter)) }
        let allFiles = gtk_file_filter_new()!
        gtk_file_filter_set_name(allFiles, "All files")
        gtk_file_filter_add_pattern(allFiles, "*")
        gtk_file_chooser_add_filter(chooser, allFiles)

        let context = Unmanaged.passRetained(PathDialogResponseAction(dialog: self)).toOpaque()
        let callback: @convention(c) (UnsafeMutablePointer<GtkNativeDialog>?, gint, gpointer?) -> Void = {
            _, response, userData in
            guard let userData else { return }
            let action = Unmanaged<PathDialogResponseAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.invoke(response: response) }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<PathDialogResponseAction>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(native), "response",
                              unsafeBitCast(callback, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(native)) }
    func present() { gtk_native_dialog_show(native) }
    func dismiss() {
        guard !completed else { return }
        completed = true
        gtk_native_dialog_hide(native)
    }

    fileprivate func handleResponse(_ response: gint) {
        guard !completed else { return }
        completed = true
        var answer: Answer = .cancelled
        if response == GTK_RESPONSE_ACCEPT.rawValue {
            if multiple, let files = gtk_file_chooser_get_files(chooser) {
                var urls: [URL] = []
                let count = g_list_model_get_n_items(files)
                for index in 0..<count {
                    guard let file = g_list_model_get_item(files, index) else { continue }
                    if let path = g_file_get_path(OpaquePointer(file)) {
                        urls.append(URL(fileURLWithPath: String(cString: path)))
                        g_free(path)
                    }
                    g_object_unref(file)
                }
                g_object_unref(UnsafeMutableRawPointer(files))
                if !urls.isEmpty { answer = .paths(urls) }
            } else if let file = gtk_file_chooser_get_file(chooser) {
                if let path = g_file_get_path(file) {
                    answer = .path(URL(fileURLWithPath: String(cString: path)))
                    g_free(path)
                }
                g_object_unref(UnsafeMutableRawPointer(file))
            }
        }
        gtk_native_dialog_hide(native)
        onComplete(answer)
    }
}
