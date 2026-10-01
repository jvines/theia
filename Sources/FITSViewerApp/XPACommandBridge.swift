import Foundation
import AppKit
import XPABridge
import TheiaKit

/// Connects libxpa callbacks to the shared DS9 command mapping.
final class XPACommandBridge: XPAServerDelegate {
    func xpaGet(command: String, params: String) -> Result<String, XPACommandError> {
        MainActor.assumeIsolated {
            let snapshot = frontController().map { controller in
                let session = controller.documentModel.session
                return XPADocumentSnapshot(
                    id: AppDelegate.shared?.scriptingID(of: controller) ?? -1,
                    path: controller.documentModel.url.path,
                    stretch: session.view.stretch,
                    colorMap: session.view.colorMap,
                    regions: session.regions,
                    zscaleContrast: session.zscaleContrastSetting
                )
            }
            return XPACommandMapper.get(command: command, params: params, document: snapshot)
                .mapError { XPACommandError($0.message) }
        }
    }

    func xpaSet(command: String, params: String, data: Data?) -> Result<Void, XPACommandError> {
        MainActor.assumeIsolated {
            let action: XPAAction
            switch XPACommandMapper.set(command: command, params: params, data: data) {
            case .success(let parsed): action = parsed
            case .failure(let error): return .failure(XPACommandError(error.message))
            }
            guard let app = AppDelegate.shared else {
                return .failure(XPACommandError("Theia is not ready"))
            }
            switch action {
            case .loadFile(let path, let newFrame):
                do {
                    let url = URL(fileURLWithPath: path)
                    if !newFrame, let controller = frontController() {
                        try app.replaceDocument(in: controller, at: url)
                    } else {
                        try app.openDocumentThrowing(at: url)
                    }
                    return .success(())
                } catch {
                    return .failure(XPACommandError("cannot open \(path): \(error.localizedDescription)"))
                }
            case .session(let commands):
                guard let session = frontController()?.documentModel.session else {
                    return .failure(XPACommandError("no image is open"))
                }
                if let failure = XPACommandMapper.perform(commands, on: session) {
                    return .failure(XPACommandError(failure.message))
                }
                return .success(())
            case .quit:
                if let failure = app.performWorkspaceCommand(.quit, origin: .script).failure {
                    return .failure(XPACommandError(failure.message))
                }
                return .success(())
            }
        }
    }

    @MainActor private func frontController() -> DocumentWindowController? {
        let controllers = AppDelegate.shared?.allControllersForScripting() ?? []
        if let key = controllers.first(where: { $0.window?.isKeyWindow == true }) { return key }
        return AppDelegate.shared?.currentController ?? controllers.last
    }
}
