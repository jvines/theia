import AppKit
import SwiftUI
import TheiaKit

/// Keeps Space playback available when a control consumes keyDown before the
/// document's SwiftUI key handlers, while routing only to this document window.
struct DocumentKeyEventMonitor: NSViewRepresentable {
    let interaction: InteractionController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(on: view, interaction: interaction)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.interaction = interaction
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func shouldRouteSpace(_ event: NSEvent, in window: NSWindow,
                                 firstResponder: NSResponder?) -> Bool {
        event.type == .keyDown &&
        event.windowNumber == window.windowNumber &&
        event.charactersIgnoringModifiers == " " &&
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty &&
        !(firstResponder is NSText)
    }

    final class Coordinator {
        weak var hostView: NSView?
        var interaction: InteractionController?
        private var monitor: Any?

        func install(on view: NSView, interaction: InteractionController) {
            hostView = view
            self.interaction = interaction
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let window = self.hostView?.window,
                      DocumentKeyEventMonitor.shouldRouteSpace(event, in: window,
                                                                firstResponder: window.firstResponder),
                      self.interaction?.key(.init(key: .space)) == true else { return event }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
