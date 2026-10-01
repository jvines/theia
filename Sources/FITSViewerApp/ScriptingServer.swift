import Foundation
import AppKit
import FITSCore
import FITSRender
import TheiaKit

/// Localhost-only HTTP scripting server. Lets external tools (curl, Python, AppleScript,
/// shell pipelines) drive an already-open Theia. Bound to 127.0.0.1 only — never
/// reachable from the network.
///
/// Routes (JSON except for .reg region text):
///   GET  /status                            → {version, beta, open: [{path, id}]}
///   POST /open  {path, stretch?, …}         → {id}
///   GET  /document/<id>/info                → {path, stretch, colormap, vmin, vmax, ...}
///   POST /document/<id>/stretch  {name}     → {ok}
///   POST /document/<id>/colormap {name}     → {ok}
///   POST /document/<id>/scale   {vmin,vmax} → {ok}
///   POST /document/<id>/zscale              → {ok}
///   GET  /document/<id>/regions             → .reg text
///   POST /document/<id>/regions  {dsl}      → {ok}     (replaces regions, body is .reg text)
///   POST /document/<id>/regions/clear       → {ok}
///   POST /quit                              → {ok}
///
/// `id` is a stable, monotonic workspace document identifier.
@MainActor
final class ScriptingServer {
    static let shared = ScriptingServer()

    private var transport: ScriptingSocketServer?
    private(set) var port: UInt16 = 0
    private(set) var isRunning: Bool = false

    /// Starts listening on the first free port in [4321, 4399]. Idempotent.
    @discardableResult
    func start() -> UInt16 {
        if isRunning { return port }
        guard !ScriptingAuth.tokenHex().isEmpty else {
            NSLog("[ScriptingServer] cannot start without a persisted auth token")
            return 0
        }
        do {
            let portFile = try AppPaths(platform: .macOS).portFile()
            let server = ScriptingSocketServer(portFileURL: portFile) { [weak self] bytes in
                self?.response(for: bytes)
            }
            let boundPort = try server.start()
            transport = server
            port = boundPort
            isRunning = true
            NSLog("[ScriptingServer] listening on 127.0.0.1:\(boundPort)")
            NSLog("[ScriptingServer] token file: \(ScriptingAuth.tokenURL().path)")
            return boundPort
        } catch {
            NSLog("[ScriptingServer] failed to start HTTP transport: \(error)")
            return 0
        }
    }

    func stop() {
        transport?.stop()
        transport = nil
        isRunning = false
        port = 0
    }

    // MARK: - Request handling

    private func response(for bytes: Data) -> ScriptingSocketReply? {
        switch ScriptingHTTPRequestParser.parse(bytes) {
        case .incomplete:
            return nil
        case .failure(let failure):
            return ScriptingSocketReply(data: httpResponse(failure.status,
                                                           json: ["error": failure.message]))
        case .request(let request):
            // Authentication follows framing checks, before route resolution.
            guard ScriptingAuth.authorise(headerValue: request.headerValue("Authorization")) else {
                return ScriptingSocketReply(data: httpResponse(
                    401, json: ["error": "missing or invalid Authorization: Bearer <token>"]))
            }
            let destination = ScriptingHTTPRouter.resolve(request)
            if case .quit = destination {
                guard let app = AppDelegate.shared else {
                    return ScriptingSocketReply(data: httpResponse(503,
                                                                  json: ["error": "app unavailable"]))
                }
                return ScriptingSocketReply(
                    data: httpResponse(200, json: ["ok": true]),
                    didSend: { [weak app] in
                        _ = app?.performWorkspaceCommand(.quit, origin: .script)
                    }
                )
            }
            return ScriptingSocketReply(data: route(request, destination: destination))
        }
    }

    // MARK: - Routes

    private func route(_ request: ScriptingHTTPRequest,
                       destination: ScriptingHTTPRoute) -> Data {
        switch destination {
        case .status:
            return statusResponse()
        case .open:
            return openResponse(body: request.body)
        case .quit:
            return httpResponse(500, json: ["error": "quit must be deferred until send completion"])
        case .document(let id, let route):
            guard let controller = controllerByIndex(id) else {
                return httpResponse(404, json: ["error": "no document with id \(id)"])
            }
            let response: Data? = controller.documentModel.session.withEventContext(origin: .script) {
                switch route {
                case .info:
                    return infoResponse(controller: controller)
                case .stretch, .colormap, .scale, .zscale:
                    guard let route else { return nil }
                    switch ScriptingHTTPRouter.command(for: route, body: request.body) {
                    case .success(let command):
                        return commandResponse(controller.documentModel.session.perform(command, origin: .script))
                    case .failure(let failure):
                        return httpResponse(failure.status, json: ["error": failure.message])
                    }
                case .regionsGet:
                    return regionsGetResponse(controller: controller)
                case .regionsPost:
                    return regionsPostResponse(controller: controller, body: request.body)
                case .regionsClear:
                    controller.setRegionsForScripting([])
                    return httpResponse(200, json: ["ok": true])
                case nil: return nil
                }
            }
            if let response { return response }
            return httpResponse(404, json: ["error": "no route"])
        case .failure(let failure):
            return httpResponse(failure.status, json: ["error": failure.message])
        }
    }

    // MARK: - Handlers

    private func controllerByIndex(_ idx: Int) -> DocumentWindowController? {
        AppDelegate.shared?.controllerForScripting(at: idx)
    }

    private func statusResponse() -> Data {
        let controllers = AppDelegate.shared?.allControllersForScripting() ?? []
        let docs: [[String: Any]] = controllers.map { c in
            ["id": AppDelegate.shared?.scriptingID(of: c) ?? -1, "path": c.documentModel.url.path]
        }
        return httpResponse(200, json: [
            "version": AppVersion.string,
            "beta": AppVersion.isBeta,
            "open": docs,
        ])
    }

    private func openResponse(body: Data) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let path = obj["path"] as? String else {
            return httpResponse(400, json: ["error": "expected {path: ...}"])
        }
        let url = URL(fileURLWithPath: path)
        let controller: DocumentWindowController
        do {
            guard let opened = try AppDelegate.shared?.openDocumentThrowing(at: url) else {
                return httpResponse(500, json: ["error": "app not ready"])
            }
            controller = opened
        } catch {
            let failure = ScriptingHTTPRouter.openFailure(error)
            return httpResponse(failure.status, json: ["error": failure.message])
        }
        // Optional params
        let session = controller.documentModel.session
        session.withEventContext(origin: .script) {
            if let s = obj["stretch"] as? String, let stretch = ImageStretch(rawValue: s) {
                session.perform(.setStretch(stretch), origin: .script)
            }
            if let s = obj["colormap"] as? String, let cm = ColorMap(rawValue: s) {
                session.perform(.setColormap(cm), origin: .script)
            }
            if let vmin = obj["vmin"] as? Double,
               let minimum = ScriptingHTTPRouter.finiteLevel(vmin) {
                session.perform(.setLevels(min: minimum, max: session.view.vmax), origin: .script)
            }
            if let vmax = obj["vmax"] as? Double,
               let maximum = ScriptingHTTPRouter.finiteLevel(vmax) {
                session.perform(.setLevels(min: session.view.vmin, max: maximum), origin: .script)
            }
            if obj["zscale"] as? Bool == true {
                session.perform(.applyScalePreset(.zscale), origin: .script)
            }
        }
        let id = AppDelegate.shared?.scriptingID(of: controller) ?? -1
        return httpResponse(200, json: ["id": id])
    }

    private func infoResponse(controller: DocumentWindowController) -> Data {
        let viewport = controller.documentModel.session.view
        let json: [String: Any] = [
            "path": controller.documentModel.url.path,
            "stretch": viewport.stretch.rawValue,
            "colormap": viewport.colorMap.rawValue,
            "vmin": Double(viewport.vmin),
            "vmax": Double(viewport.vmax),
            "stretchParameter": Double(viewport.stretchParameter)
        ]
        return httpResponse(200, json: json)
    }

    private func regionsGetResponse(controller: DocumentWindowController) -> Data {
        let text = RegionFile.format(controller.regionsForScripting())
        return httpResponse(200, body: Data(text.utf8), contentType: "text/plain")
    }

    private func regionsPostResponse(controller: DocumentWindowController, body: Data) -> Data {
        guard let text = String(data: body, encoding: .utf8),
              let regs = try? RegionFile.parse(text) else {
            return httpResponse(400, json: ["error": "couldn't parse body as .reg region text"])
        }
        controller.setRegionsForScripting(regs)
        return httpResponse(200, json: ["ok": true, "n": regs.count])
    }

    // MARK: - HTTP helpers

    private func commandResponse(_ outcome: CommandOutcome) -> Data {
        if let failure = outcome.failure {
            return httpResponse(400, json: ["error": failure.message])
        }
        return httpResponse(200, json: ["ok": true])
    }

    private func httpResponse(_ status: Int, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return httpResponse(status, body: body, contentType: "application/json")
    }

    private func httpResponse(_ status: Int, body: Data, contentType: String) -> Data {
        let reason = [
            "200": "OK",
            "400": "Bad Request",
            "401": "Unauthorized",
            "404": "Not Found",
            "413": "Payload Too Large",
            "431": "Request Header Fields Too Large",
            "500": "Internal Server Error",
        ]["\(status)"] ?? "OK"
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Length: \(body.count)",
            "Content-Type: \(contentType)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var out = Data(headers.utf8)
        out.append(body)
        return out
    }
}
