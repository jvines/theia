import SwiftUI
import AppKit

/// Installs an `NSEvent.addLocalMonitorForEvents` keyDown hook for the lifetime of
/// the host view. Use to intercept keys that SwiftUI's `.onKeyPress` doesn't reach
/// because some focused control swallows them first.
struct KeyEventMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(handle: handle)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var handle: ((NSEvent) -> NSEvent?)?
        private var monitor: Any?

        func install(handle: @escaping (NSEvent) -> NSEvent?) {
            self.handle = handle
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handle?(event) ?? event
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
