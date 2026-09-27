import Foundation
import AppKit
import XPABridge
import TheiaKit

/// Connects libxpa callbacks to the shared DS9 command mapping.
final class XPACommandBridge: XPAServerDelegate {
    func xpaGet(command: String, params: String) -> String? {
        MainActor.assumeIsolated {
            let snapshot = frontController().map { controller in
                let session = controller.documentModel.session
                return XPADocumentSnapshot(
                    id: AppDelegate.shared?.scriptingID(of: controller) ?? -1,
                    path: controller.documentModel.url.path,
                    stretch: session.view.stretch,
                    colorMap: session.view.colorMap,
                    regions: session.regions
                )
            }
            return XPACommandMapper.get(command: command, params: params, document: snapshot)
        }
    }

    func xpaSet(command: String, params: String, data: Data?) -> Bool {
        MainActor.assumeIsolated {
            guard let action = XPACommandMapper.set(command: command, params: params, data: data)
            else { return false }
            switch action {
            case .openFile(let path):
                guard let app = AppDelegate.shared else { return false }
                do {
                    try app.openDocumentThrowing(at: URL(fileURLWithPath: path))
                    return true
                } catch {
                    return false
                }
            case .session(let command):
                guard let session = frontController()?.documentModel.session else { return false }
                return session.perform(command, origin: .script).failure == nil
            case .quit:
                guard let app = AppDelegate.shared else { return false }
                return app.performWorkspaceCommand(.quit, origin: .script).failure == nil
            }
        }
    }

    @MainActor private func frontController() -> DocumentWindowController? {
        let controllers = AppDelegate.shared?.allControllersForScripting() ?? []
        if let key = controllers.first(where: { $0.window?.isKeyWindow == true }) { return key }
        return AppDelegate.shared?.currentController ?? controllers.last
    }
}
