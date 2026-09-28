import FITSCore
import Foundation
import TheiaKit

/// Linux adapter for the shared loopback HTTP transport and route parser.
@MainActor final class GTKScriptingServer {
    private weak var controller: GTKApplicationController?
    private let paths: AppPaths
    private let runtimeDirectory: URL?
    private let portRange: ClosedRange<UInt16>
    private var token: String?
    private var transport: ScriptingSocketServer?
    var port: UInt16 { transport?.port ?? 0 }

    init(controller: GTKApplicationController, token: String? = nil,
         paths: AppPaths = AppPaths(platform: .linux),
         runtimeDirectory: URL? = nil,
         portRange: ClosedRange<UInt16> = 4321...4399) {
        self.controller = controller
        self.token = token
        self.paths = paths
        self.runtimeDirectory = runtimeDirectory
        self.portRange = portRange
    }

    @discardableResult func start() throws -> UInt16 {
        if let transport { return transport.port }
        let tokenFile = try runtimeDirectory?.appendingPathComponent("scripting-token")
            ?? paths.tokenFile()
        let portFile = try runtimeDirectory?.appendingPathComponent("scripting-port")
            ?? paths.portFile()
        let token = try token ?? ScriptingTokenStore(url: tokenFile).loadOrCreate()
        self.token = token
        let server = ScriptingSocketServer(portFileURL: portFile, portRange: portRange) {
            [weak self] bytes in self?.response(for: bytes)
        }
        let port = try server.start()
        transport = server
        return port
    }

    func stop() {
        transport?.stop()
        transport = nil
    }

    func response(for bytes: Data) -> ScriptingSocketReply? {
        switch ScriptingHTTPRequestParser.parse(bytes) {
        case .incomplete:
            return nil
        case .failure(let failure):
            return ScriptingSocketReply(data: httpResponse(failure.status, json: ["error": failure.message]))
        case .request(let request):
            guard let token,
                  ScriptingTokenStore.authorise(
                    headerValue: request.headerValue("Authorization"), token: token
                  ) else {
                return ScriptingSocketReply(data: httpResponse(
                    401, json: ["error": "missing or invalid Authorization: Bearer <token>"]
                ))
            }
            let destination = ScriptingHTTPRouter.resolve(request)
            if case .quit = destination {
                guard let controller else {
                    return ScriptingSocketReply(data: httpResponse(503, json: ["error": "app unavailable"]))
                }
                return ScriptingSocketReply(
                    data: httpResponse(200, json: ["ok": true]),
                    didSend: { [weak controller] in controller?.quitForScripting() }
                )
            }
            return ScriptingSocketReply(data: route(request, destination: destination))
        }
    }

    private func route(_ request: ScriptingHTTPRequest,
                       destination: ScriptingHTTPRoute) -> Data {
        guard let controller else { return httpResponse(503, json: ["error": "app unavailable"]) }
        switch destination {
        case .status:
            let documents: [[String: Any]] = controller.documentWindowsForScripting.map { window in
                ["id": controller.scriptingID(of: window) ?? -1, "path": window.session.url.path]
            }
            return httpResponse(200, json: [
                "version": AppVersion.string, "beta": AppVersion.isBeta, "open": documents,
            ])
        case .open:
            return openResponse(request.body, controller: controller)
        case .document(let id, let documentRoute):
            guard let session = controller.sessionForScripting(at: id) else {
                return httpResponse(404, json: ["error": "no document with id \(id)"])
            }
            return documentResponse(documentRoute, body: request.body, session: session)
        case .failure(let failure):
            return httpResponse(failure.status, json: ["error": failure.message])
        case .quit:
            return httpResponse(500, json: ["error": "quit must be deferred until send completion"])
        }
    }

    private func openResponse(_ body: Data, controller: GTKApplicationController) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let path = object["path"] as? String else {
            return httpResponse(400, json: ["error": "expected {path: ...}"])
        }
        let window: GTKDocumentWindow
        do {
            window = try controller.open(path: path)
        } catch {
            return httpResponse(500, json: ["error": "failed to open: \(error.localizedDescription)"])
        }
        let session = window.session
        session.withEventContext(origin: .script) {
            if let name = object["stretch"] as? String,
               let stretch = ImageStretch(rawValue: name) {
                _ = session.perform(.setStretch(stretch), origin: .script)
            }
            if let name = object["colormap"] as? String,
               let colorMap = ColorMap(rawValue: name) {
                _ = session.perform(.setColormap(colorMap), origin: .script)
            }
            if let value = object["vmin"] as? Double,
               let minimum = ScriptingHTTPRouter.finiteLevel(value) {
                _ = session.perform(.setLevels(min: minimum, max: session.view.vmax), origin: .script)
            }
            if let value = object["vmax"] as? Double,
               let maximum = ScriptingHTTPRouter.finiteLevel(value) {
                _ = session.perform(.setLevels(min: session.view.vmin, max: maximum), origin: .script)
            }
            if object["zscale"] as? Bool == true {
                _ = session.perform(.applyScalePreset(.zscale), origin: .script)
            }
        }
        return httpResponse(200, json: ["id": controller.scriptingID(of: window) ?? -1])
    }

    private func documentResponse(_ route: ScriptingDocumentRoute?, body: Data,
                                  session: DocumentSession) -> Data {
        session.withEventContext(origin: .script) {
            switch route {
            case .info:
                return httpResponse(200, json: [
                    "path": session.url.path,
                    "stretch": session.view.stretch.rawValue,
                    "colormap": session.view.colorMap.rawValue,
                    "vmin": Double(session.view.vmin),
                    "vmax": Double(session.view.vmax),
                    "stretchParameter": Double(session.view.stretchParameter),
                ])
            case .stretch, .colormap, .scale, .zscale:
                guard let route else { return httpResponse(404, json: ["error": "no route"]) }
                switch ScriptingHTTPRouter.command(for: route, body: body) {
                case .success(let command):
                    return commandResponse(session.perform(command, origin: .script))
                case .failure(let failure):
                    return httpResponse(failure.status, json: ["error": failure.message])
                }
            case .regionsGet:
                return httpResponse(200, body: Data(RegionFile.format(session.regions).utf8),
                                    contentType: "text/plain")
            case .regionsPost:
                guard let text = String(data: body, encoding: .utf8),
                      let regions = try? RegionFile.parse(text) else {
                    return httpResponse(400, json: ["error": "couldn't parse body as .reg region text"])
                }
                let outcome = session.perform(.replaceRegions(regions), origin: .script)
                if outcome.failure != nil { return commandResponse(outcome) }
                return httpResponse(200, json: ["ok": true, "n": regions.count])
            case .regionsClear:
                return commandResponse(session.perform(.clearRegions, origin: .script))
            case nil:
                return httpResponse(404, json: ["error": "no route"])
            }
        }
    }

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
            200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
            413: "Payload Too Large", 431: "Request Header Fields Too Large",
            500: "Internal Server Error", 503: "Service Unavailable",
        ][status] ?? "OK"
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Length: \(body.count)",
            "Content-Type: \(contentType)",
            "Connection: close", "", "",
        ].joined(separator: "\r\n")
        var result = Data(header.utf8)
        result.append(body)
        return result
    }
}
