import CGtk4
import Foundation
import TheiaKit
import XPABridge

/// DS9-compatible XPA callbacks run on the main queue through the GTK bridge.
final class GTKXPACommandBridge: XPAServerDelegate {
    private weak var controller: GTKApplicationController?

    init(controller: GTKApplicationController) { self.controller = controller }

    func xpaGet(command: String, params: String) -> Result<String, XPACommandError> {
        MainActor.assumeIsolated {
            let snapshot = frontWindow().map { window in
                XPADocumentSnapshot(
                    id: controller?.scriptingID(of: window) ?? -1,
                    path: window.session.url.path,
                    stretch: window.session.view.stretch,
                    colorMap: window.session.view.colorMap,
                    regions: window.session.regions,
                    zscaleContrast: window.session.zscaleContrastSetting
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
            guard let controller else { return .failure(XPACommandError("Theia is shutting down")) }
            switch action {
            case .loadFile(let path, let newFrame):
                do {
                    let url = URL(fileURLWithPath: path)
                    if !newFrame, let window = frontWindow() {
                        _ = try controller.replaceDocument(in: window, with: url)
                    } else {
                        _ = try controller.open(url: url)
                    }
                    return .success(())
                } catch {
                    return .failure(XPACommandError("cannot open \(path): \(error.localizedDescription)"))
                }
            case .session(let commands):
                guard let session = frontWindow()?.session else {
                    return .failure(XPACommandError("no image is open"))
                }
                if let failure = XPACommandMapper.perform(commands, on: session) {
                    return .failure(XPACommandError(failure.message))
                }
                return .success(())
            case .quit:
                controller.scheduleQuitForXPA()
                return .success(())
            }
        }
    }

    @MainActor private func frontWindow() -> GTKDocumentWindow? {
        guard let windows = controller?.documentWindowsForScripting else { return nil }
        return windows.first { gtk_window_is_active($0.widget) != 0 } ?? windows.last
    }
}
