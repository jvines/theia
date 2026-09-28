import CGtk4
import Dispatch
import Glibc

// Swift's main executor uses libdispatch. GTK runs GLib's main context on
// this thread, so its poll loop must also drain libdispatch's eventfd.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> Int32

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func drainDispatchMainQueue(_ message: UnsafeMutableRawPointer?)

final class GTKMainLoopBridge {
    private var sourceID: guint = 0

    func install() -> Bool {
        if sourceID != 0 { return true }
        let descriptor = dispatchMainQueueHandle()
        guard descriptor >= 0 else { return false }
        sourceID = g_unix_fd_add(descriptor, G_IO_IN, { fd, _, _ in
            var count: UInt64 = 0
            _ = read(fd, &count, MemoryLayout<UInt64>.size)
            drainDispatchMainQueue(nil)
            return 1
        }, nil)
        return sourceID != 0
    }

    func remove() {
        guard sourceID != 0 else { return }
        g_source_remove(sourceID)
        sourceID = 0
    }

    deinit { remove() }
}
