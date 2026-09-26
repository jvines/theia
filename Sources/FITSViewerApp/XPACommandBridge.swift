import Foundation
import AppKit
import FITSCore
import XPABridge

/// Maps DS9-style XPA commands onto the app, reusing the same controller hooks
/// as the HTTP scripting server. libxpa invokes these on the polling (main)
/// queue, so we run the work main-actor-isolated.
final class XPACommandBridge: XPAServerDelegate {

    func xpaGet(command: String, params: String) -> String? {
        MainActor.assumeIsolated { getMain(command: command, params: params) }
    }

    func xpaSet(command: String, params: String, data: Data?) -> Bool {
        MainActor.assumeIsolated { setMain(command: command, params: params, data: data) }
    }

    // MARK: - get (xpaget)

    @MainActor
    private func getMain(command: String, params: String) -> String? {
        switch command {
        case "version":
            return "Theia \(appVersion)"
        case "file":
            return frontController()?.documentModel.url.path
        case "frame":
            // DS9 `frame` GET returns the current frame number (1-based), not the
            // count of open frames. Use the document's stable scripting id so the
            // number doesn't shift when another window closes.
            guard let front = frontController() else { return "0" }
            return String((AppDelegate.shared?.scriptingID(of: front) ?? -1) + 1)
        case "scale":
            return frontController().map { ds9Scale(from: $0.documentModel.session.view.stretch) }
        case "cmap":
            return frontController()?.documentModel.session.view.colorMap.rawValue.lowercased()
        case "regions":
            return frontController().map { RegionFile.format($0.regionsForScripting()) }
        default:
            return nil   // unsupported → libxpa reports an error to the client
        }
    }

    // MARK: - set (xpaset)

    @MainActor
    private func setMain(command: String, params: String, data: Data?) -> Bool {
        let p = params.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case "file", "fits":
            let path = p.isEmpty ? stringFrom(data) : p
            guard let path, !path.isEmpty else { return false }
            do {
                try AppDelegate.shared?.openDocumentThrowing(at: URL(fileURLWithPath: path))
                return true
            } catch {
                return false   // libxpa surfaces the failure to the client
            }

        case "scale":
            guard let c = frontController() else { return false }
            let toks = p.split(separator: " ").map(String.init)
            switch toks.first {
            case "limits" where toks.count >= 3:
                guard let lo = Double(toks[1]), let hi = Double(toks[2]) else { return false }
                c.documentModel.session.view.vmin = Float(lo)
                c.documentModel.session.view.vmax = Float(hi)
                return true
            case "mode":
                // DS9 "scale mode zscale|minmax|<percent>". Map to the real preset
                // and reject unknown tokens instead of silently running zscale.
                guard toks.count >= 2 else { return false }
                switch toks[1].lowercased() {
                case "zscale": c.documentModel.session.resetLevels()
                case "minmax": c.documentModel.session.setMinMaxLevels()
                default:
                    // Numeric percentile, e.g. `scale mode 99.5` → clip (100−p)/2 each end.
                    guard let pct = Double(toks[1]), pct > 0, pct <= 100 else { return false }
                    let tail = (100 - pct) / 2
                    c.documentModel.session.setPercentileLevels(lower: tail, upper: 100 - tail)
                }
                return true
            default:
                guard let s = appStretch(fromDS9: p) else { return false }
                c.documentModel.session.view.stretch = s
                return true
            }

        case "cmap":
            guard let c = frontController(), let cm = appColorMap(fromDS9: p) else { return false }
            c.documentModel.session.view.colorMap = cm
            return true

        case "zscale":
            guard let c = frontController() else { return false }
            c.documentModel.session.resetLevels()
            return true

        case "regions":
            guard let c = frontController() else { return false }
            let text = stringFrom(data) ?? p
            guard let regs = try? RegionFile.parse(text) else { return false }
            c.setRegionsForScripting(regs)
            return true

        case "exit", "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        default:
            return false
        }
    }

    // MARK: - Helpers

    @MainActor
    private func frontController() -> DocumentWindowController? {
        let controllers = AppDelegate.shared?.allControllersForScripting() ?? []
        if let key = controllers.first(where: { $0.window?.isKeyWindow == true }) { return key }
        return AppDelegate.shared?.currentController ?? controllers.last
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func stringFrom(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DS9 scale name → our `ImageStretch`. DS9 uses `pow`/`histequal`.
    private func appStretch(fromDS9 name: String) -> ImageStretch? {
        switch name.lowercased() {
        case "pow", "power", "squared": return .power
        case "histequal", "histogrameq": return .histogramEq
        default: return ImageStretch(rawValue: name.lowercased())
        }
    }

    private func ds9Scale(from stretch: ImageStretch) -> String {
        switch stretch {
        case .power: return "pow"
        case .histogramEq: return "histequal"
        default: return stretch.rawValue
        }
    }

    /// DS9 colormap name → our `ColorMap`.
    private func appColorMap(fromDS9 name: String) -> ColorMap? {
        switch name.lowercased() {
        case "grey", "gray": return .gray
        default: return ColorMap(rawValue: name.lowercased())
        }
    }
}
