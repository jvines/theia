import CGtk4
import Foundation
import TheiaKit
import XPABridge

/// DS9-compatible XPA callbacks run on the main queue through the GTK bridge.
final class GTKXPACommandBridge: XPAServerDelegate {
    private weak var controller: GTKApplicationController?

    init(controller: GTKApplicationController) { self.controller = controller }

    func xpaGet(command: String, params: String) -> String? {
        MainActor.assumeIsolated {
            let snapshot = frontWindow().map { window in
                XPADocumentSnapshot(
                    id: controller?.scriptingID(of: window) ?? -1,
                    path: window.session.url.path,
                    stretch: window.session.view.stretch,
                    colorMap: window.session.view.colorMap,
                    regions: window.session.regions
                )
            }
            return XPACommandMapper.get(command: command, params: params, document: snapshot)
        }
    }

    func xpaSet(command: String, params: String, data: Data?) -> Bool {
        MainActor.assumeIsolated {
            guard let action = XPACommandMapper.set(command: command, params: params, data: data),
                  let controller else { return false }
            switch action {
            case .openFile(let path):
                return (try? controller.open(path: path)) != nil
            case .session(let command):
                guard let session = frontWindow()?.session else { return false }
                return session.perform(command, origin: .script).failure == nil
            case .quit:
                controller.scheduleQuitForXPA()
                return true
            }
        }
    }

    @MainActor private func frontWindow() -> GTKDocumentWindow? {
        guard let windows = controller?.documentWindowsForScripting else { return nil }
        return windows.first { gtk_window_is_active($0.widget) != 0 } ?? windows.last
    }
}
