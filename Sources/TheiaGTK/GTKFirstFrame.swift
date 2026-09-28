import CGtk4

/// Runs an action once, after a window has painted its first frame. Wayland
/// compositors ignore a transient parent that has not mapped yet, so a child
/// presented in the same main-loop turn as its parent is tiled like any other
/// window instead of floating over it.
@MainActor final class GTKFirstFrame {
    private let action: @MainActor () -> Void
    private var clock: OpaquePointer?
    private var handlerID: gulong = 0

    private init(_ action: @escaping @MainActor () -> Void) { self.action = action }

    static func after(_ window: UnsafeMutablePointer<GtkWindow>,
                      perform action: @escaping @MainActor () -> Void) {
        let widget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(window))
        guard let native = gtk_widget_get_native(widget),
              let surface = gtk_native_get_surface(native),
              let clock = gdk_surface_get_frame_clock(surface) else {
            action()
            return
        }
        let pending = GTKFirstFrame(action)
        pending.clock = clock
        let context = Unmanaged.passRetained(pending).toOpaque()
        let painted: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let pending = Unmanaged<GTKFirstFrame>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { pending.fire() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKFirstFrame>.fromOpaque(userData).release()
        }
        pending.handlerID = g_signal_connect_data(
            UnsafeMutableRawPointer(clock), "after-paint",
            unsafeBitCast(painted, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
    }

    private func fire() {
        guard let clock, handlerID != 0 else { return }
        let id = handlerID
        handlerID = 0
        self.clock = nil
        action()
        g_signal_handler_disconnect(UnsafeMutableRawPointer(clock), id)
    }
}
