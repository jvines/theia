import Foundation
import Network
import AppKit
import FITSCore
import FITSRender

/// Localhost-only HTTP scripting server. Lets external tools (curl, Python, AppleScript,
/// shell pipelines) drive an already-open Theia. Bound to 127.0.0.1 only — never
/// reachable from the network.
///
/// Routes (all JSON):
///   GET  /status                            → {open: [{path, id}]}
///   POST /open  {path, stretch?, …}         → {id}
///   GET  /document/<id>/info                → {path, stretch, colormap, vmin, vmax, ...}
///   POST /document/<id>/stretch  {name}     → {ok}
///   POST /document/<id>/colormap {name}     → {ok}
///   POST /document/<id>/scale   {vmin,vmax} → {ok}
///   POST /document/<id>/zscale              → {ok}
///   GET  /document/<id>/regions             → {regions: [...]}
///   POST /document/<id>/regions  {dsl}      → {ok}     (replaces regions, body is .reg text)
///   POST /document/<id>/regions/clear       → {ok}
///   POST /quit                              → {ok}
///
/// `id` is a 0-based index into the active controllers list.
@MainActor
final class ScriptingServer {
    static let shared = ScriptingServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private(set) var isRunning: Bool = false

    /// Hard cap on the accumulated body size of a single request. 16 MB is well
    /// above any plausible legitimate region-text or open-document JSON payload
    /// and protects against a malicious local process exhausting RAM.
    private static let maxBodyBytes: Int = 16 * 1024 * 1024
    /// Hard cap on the accumulated header size — any well-behaved client fits
    /// within 16 kB.
    private static let maxHeaderBytes: Int = 16 * 1024

    /// Starts listening on the first free port in [4321, 4399]. Idempotent — a
    /// second call is a no-op. Binding is confirmed asynchronously via the
    /// listener's state handler (the actual port is announced in the log once the
    /// listener reaches `.ready`), so this returns the current `port` (0 until
    /// ready) rather than a bind result.
    @discardableResult
    func start() -> UInt16 {
        if isRunning { return port }
        bind(startingAt: 4321)
        return port
    }

    /// Attempts to bind `tryPort`, installing a state handler so that a port that
    /// is already in use (NWListener surfaces that as an async `.failed` state, not
    /// a synchronous throw) actually falls through to the next port instead of
    /// silently pretending to listen.
    private func bind(startingAt tryPort: Int) {
        guard tryPort <= 4399 else {
            NSLog("[ScriptingServer] failed to bind any port in 4321-4399")
            return
        }
        let params = NWParameters.tcp
        // 127.0.0.1 only — restrict to the loopback interface.
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        params.requiredInterfaceType = .loopback
        let l: NWListener
        do {
            l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(tryPort)))
        } catch {
            NSLog("[ScriptingServer] bind \(tryPort) failed: \(error)")
            bind(startingAt: tryPort + 1)
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handle(connection: conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener = l
                    self.port = UInt16(tryPort)
                    self.isRunning = true
                    NSLog("[ScriptingServer] listening on 127.0.0.1:\(tryPort)")
                    // Eagerly materialise the auth token so the file exists before
                    // any client tries to read it.
                    _ = ScriptingAuth.tokenHex()
                    NSLog("[ScriptingServer] token file: \(ScriptingAuth.tokenURL().path)")
                case .failed(let error):
                    NSLog("[ScriptingServer] bind \(tryPort) failed: \(error)")
                    l.cancel()
                    if !self.isRunning { self.bind(startingAt: tryPort + 1) }
                default:
                    break
                }
            }
        }
        l.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection / request handling

    private func handle(connection conn: NWConnection) {
        conn.start(queue: .main)
        receive(connection: conn, buffer: Data())
    }

    private func receive(connection conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let d = data { buf.append(d) }
                // Hard cap on accumulated bytes — a malicious local client can't
                // make us buffer indefinitely.
                if buf.count > Self.maxHeaderBytes + Self.maxBodyBytes {
                    let resp = self.httpResponse(413, json: ["error": "request too large"])
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if buf.count > Self.maxHeaderBytes {
                        let resp = self.httpResponse(431, json: ["error": "header too large"])
                        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                        return
                    }
                    if isComplete || error != nil { conn.cancel(); return }
                    self.receive(connection: conn, buffer: buf)
                    return
                }
                // Enforce the header cap here too: a complete header that arrives in
                // one burst reaches this path without ever hitting the incomplete-read
                // check above, so an oversized header would otherwise slip through.
                if headerEnd.lowerBound > Self.maxHeaderBytes {
                    let resp = self.httpResponse(431, json: ["error": "header too large"])
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
                let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                let rawCL = parseContentLength(headerStr) ?? 0
                guard rawCL >= 0 else {
                    let resp = self.httpResponse(400, json: ["error": "invalid content-length"])
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                guard rawCL <= Self.maxBodyBytes else {
                    let resp = self.httpResponse(413, json: ["error": "request body too large"])
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                let contentLength = rawCL
                let bodyStart = headerEnd.upperBound
                let bodyHave = buf.count - bodyStart
                if bodyHave < contentLength {
                    if isComplete || error != nil { conn.cancel(); return }
                    self.receive(connection: conn, buffer: buf)
                    return
                }
                let body = contentLength > 0 ? buf.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
                // Auth gate — every request must carry the bearer token.
                let authHeader = parseHeaderValue(headerStr, name: "Authorization")
                guard ScriptingAuth.authorise(headerValue: authHeader) else {
                    let resp = self.httpResponse(401, json: ["error": "missing or invalid Authorization: Bearer <token>"])
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                let response = self.route(headerStr: headerStr, body: body)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: - Routes

    private func route(headerStr: String, body: Data) -> Data {
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return httpResponse(400, json: ["error": "bad request"]) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return httpResponse(400, json: ["error": "bad request line"]) }
        let method = String(parts[0])
        let path = String(parts[1])

        switch (method, path) {
        case ("GET", "/status"):
            return statusResponse()
        case ("POST", "/open"):
            return openResponse(body: body)
        case ("POST", "/quit"):
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return httpResponse(200, json: ["ok": true])
        default: break
        }

        // /document/<id>/...
        if path.hasPrefix("/document/") {
            let stripped = String(path.dropFirst("/document/".count))
            let segments = stripped.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            guard let id = Int(segments[0]) else { return httpResponse(404, json: ["error": "bad id"]) }
            // Reconstruct the whole sub-path so an unexpected extra segment (e.g.
            // /document/0/info/junk) falls through to 404 instead of matching just
            // the second segment, and multi-segment routes like regions/clear match.
            let sub = segments.dropFirst().joined(separator: "/")
            guard let controller = controllerByIndex(id) else {
                return httpResponse(404, json: ["error": "no document with id \(id)"])
            }
            switch (method, sub) {
            case ("GET", "info"):
                return infoResponse(controller: controller)
            case ("POST", "stretch"):
                return setStretchResponse(controller: controller, body: body)
            case ("POST", "colormap"):
                return setColormapResponse(controller: controller, body: body)
            case ("POST", "scale"):
                return setScaleResponse(controller: controller, body: body)
            case ("POST", "zscale"):
                controller.toolbarState.onZScale()
                return httpResponse(200, json: ["ok": true])
            case ("GET", "regions"):
                return regionsGetResponse(controller: controller)
            case ("POST", "regions"):
                return regionsPostResponse(controller: controller, body: body)
            case ("POST", "regions/clear"):
                controller.setRegionsForScripting([])
                return httpResponse(200, json: ["ok": true])
            default: break
            }
        }
        return httpResponse(404, json: ["error": "no route"])
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
        return httpResponse(200, json: ["open": docs])
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
            return httpResponse(500, json: ["error": "failed to open: \(error.localizedDescription)"])
        }
        // Optional params
        if let s = obj["stretch"] as? String, let stretch = ImageStretch(rawValue: s) {
            controller.toolbarState.onSelectStretch(stretch)
        }
        if let s = obj["colormap"] as? String, let cm = ColorMap(rawValue: s) {
            controller.toolbarState.onSelectMap(cm)
        }
        if let vmin = obj["vmin"] as? Double { controller.documentModel.session.view.vmin = Float(vmin) }
        if let vmax = obj["vmax"] as? Double { controller.documentModel.session.view.vmax = Float(vmax) }
        if obj["zscale"] as? Bool == true { controller.toolbarState.onZScale() }
        let id = AppDelegate.shared?.scriptingID(of: controller) ?? -1
        return httpResponse(200, json: ["id": id])
    }

    private func infoResponse(controller: DocumentWindowController) -> Data {
        let toolbar = controller.toolbarState
        let viewport = controller.documentModel.session.view
        let json: [String: Any] = [
            "path": controller.documentModel.url.path,
            "stretch": toolbar.stretch.rawValue,
            "colormap": toolbar.colorMap.rawValue,
            "vmin": Double(viewport.vmin),
            "vmax": Double(viewport.vmax),
            "stretchParameter": Double(viewport.stretchParameter)
        ]
        return httpResponse(200, json: json)
    }

    private func setStretchResponse(controller: DocumentWindowController, body: Data) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let name = obj["name"] as? String,
              let s = ImageStretch(rawValue: name) else {
            return httpResponse(400, json: ["error": "expected {name: <stretch>}"])
        }
        controller.toolbarState.onSelectStretch(s)
        return httpResponse(200, json: ["ok": true])
    }

    private func setColormapResponse(controller: DocumentWindowController, body: Data) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let name = obj["name"] as? String,
              let cm = ColorMap(rawValue: name) else {
            return httpResponse(400, json: ["error": "expected {name: <colormap>}"])
        }
        controller.toolbarState.onSelectMap(cm)
        return httpResponse(200, json: ["ok": true])
    }

    private func setScaleResponse(controller: DocumentWindowController, body: Data) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let vmin = obj["vmin"] as? Double,
              let vmax = obj["vmax"] as? Double else {
            return httpResponse(400, json: ["error": "expected {vmin, vmax}"])
        }
        controller.documentModel.session.view.vmin = Float(vmin)
        controller.documentModel.session.view.vmax = Float(vmax)
        return httpResponse(200, json: ["ok": true])
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

/// Returns the parsed Content-Length, or:
///   - `nil` if no header is present (caller may treat as 0)
///   - `Int.min` to signal a malformed value (negative, `+` sign, leading zero,
///     non-digits, multiple Content-Length headers — all of which are smuggling
///     shapes the caller must reject with 400).
private func parseContentLength(_ header: String) -> Int? {
    var found: String? = nil
    let target = "content-length"
    for line in header.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              parts[0].lowercased().trimmingCharacters(in: .whitespaces) == target else { continue }
        if found != nil { return Int.min }  // multiple Content-Length headers
        found = parts[1].trimmingCharacters(in: .whitespaces)
    }
    guard let raw = found else { return nil }
    // Only accept pure decimal digits. Reject `+N`, `-N`, leading zeros (except
    // exactly "0"), whitespace, hex, etc.
    guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return Int.min }
    if raw.count > 1 && raw.first == "0" { return Int.min }
    return Int(raw) ?? Int.min
}

private func parseHeaderValue(_ header: String, name: String) -> String? {
    let target = name.lowercased()
    for line in header.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == target {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}
