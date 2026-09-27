import AppKit
import TheiaKit

/// Mac window ownership and tiling. Session synchronization lives in Workspace.
@MainActor
final class WindowSyncCoordinator {
    static let shared = WindowSyncCoordinator()

    let workspace = Workspace()

    private struct Entry {
        weak var controller: DocumentWindowController?
    }
    private var entries: [Entry] = []

    func register(_ controller: DocumentWindowController) {
        entries.removeAll { $0.controller == nil }
        guard !entries.contains(where: { $0.controller === controller }) else { return }
        entries.append(Entry(controller: controller))
        workspace.register(controller.documentModel.session)
    }

    func unregister(_ controller: DocumentWindowController) {
        workspace.unregister(controller.documentModel.session)
        entries.removeAll { $0.controller === controller || $0.controller == nil }
    }

    /// Arrange all registered windows in a horizontal row across the active screen.
    func tileWindowsHorizontally() {
        let liveControllers = entries.compactMap { $0.controller }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame, !liveControllers.isEmpty else { return }
        let count = CGFloat(liveControllers.count)
        let width = frame.width / count
        for (index, controller) in liveControllers.enumerated() {
            let windowFrame = NSRect(x: frame.minX + CGFloat(index) * width, y: frame.minY,
                                     width: width, height: frame.height)
            controller.window?.setFrame(windowFrame, display: true, animate: true)
        }
    }
}
