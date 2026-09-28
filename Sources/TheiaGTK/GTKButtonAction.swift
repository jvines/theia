import CGtk4

@MainActor final class GTKButtonAction {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) { self.action = action }

    func connect(to button: UnsafeMutablePointer<GtkWidget>) {
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let action = Unmanaged<GTKButtonAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.action() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKButtonAction>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(button), "clicked",
            unsafeBitCast(callback, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
    }
}
