import CGtk4
import Foundation

@MainActor private final class URILaunch {
    let launcher: OpaquePointer
    let onFailure: @MainActor (String) -> Void

    init(launcher: OpaquePointer, onFailure: @escaping @MainActor (String) -> Void) {
        self.launcher = launcher
        self.onFailure = onFailure
    }
}

/// Launches help links through GIO without entering a nested GTK loop.
@MainActor enum GTKURLOpener {
    static func open(_ url: URL, parent: UnsafeMutablePointer<GtkWindow>?,
                     onFailure: @escaping @MainActor (String) -> Void) {
        guard let launcher = gtk_uri_launcher_new(url.absoluteString) else {
            onFailure("Could not open \(url.absoluteString)")
            return
        }
        let context = Unmanaged.passRetained(URILaunch(launcher: launcher,
                                                      onFailure: onFailure)).toOpaque()
        let completed: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = {
            _, result, userData in
            guard let result, let userData else { return }
            let launch = Unmanaged<URILaunch>.fromOpaque(userData).takeRetainedValue()
            MainActor.assumeIsolated {
                var error: UnsafeMutablePointer<GError>?
                if gtk_uri_launcher_launch_finish(launch.launcher, result, &error) == 0 {
                    let message = error.map { String(cString: $0.pointee.message) }
                        ?? "No application is available for this link"
                    launch.onFailure(message)
                }
                if let error { g_error_free(error) }
                g_object_unref(UnsafeMutableRawPointer(launch.launcher))
            }
        }
        gtk_uri_launcher_launch(launcher, parent, nil,
                                unsafeBitCast(completed, to: GAsyncReadyCallback.self), context)
    }
}
