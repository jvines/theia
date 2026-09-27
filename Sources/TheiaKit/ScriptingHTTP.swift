import Foundation
import FITSCore

public struct ScriptingHTTPFailure: Error, Equatable, Sendable {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

public struct ScriptingHTTPRequest: Equatable, Sendable {
    public let header: String
    public let body: Data

    public func headerValue(_ name: String) -> String? {
        let target = name.lowercased()
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].lowercased().trimmingCharacters(in: .whitespaces) == target {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

public enum ScriptingHTTPParseResult: Equatable, Sendable {
    case incomplete
    case failure(ScriptingHTTPFailure)
    case request(ScriptingHTTPRequest)
}

/// Inspects the bytes accumulated for one HTTP request. The transport owns reads
/// and connection lifetime; this parser never buffers more data itself.
public enum ScriptingHTTPRequestParser {
    public static let maxBodyBytes = 16 * 1024 * 1024
    public static let maxHeaderBytes = 16 * 1024

    public static func parse(_ buffer: Data) -> ScriptingHTTPParseResult {
        if buffer.count > maxHeaderBytes + maxBodyBytes {
            return .failure(.init(status: 413, message: "request too large"))
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes
                ? .failure(.init(status: 431, message: "header too large")) : .incomplete
        }
        if headerEnd.lowerBound > maxHeaderBytes {
            return .failure(.init(status: 431, message: "header too large"))
        }

        let header = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        let rawLength = contentLength(in: header) ?? 0
        if rawLength < 0 {
            return .failure(.init(status: 400, message: "invalid content-length"))
        }
        if rawLength > maxBodyBytes {
            return .failure(.init(status: 413, message: "request body too large"))
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= rawLength else { return .incomplete }
        let body = rawLength == 0 ? Data() : buffer.subdata(in: bodyStart..<(bodyStart + rawLength))
        return .request(.init(header: header, body: body))
    }

    private static func contentLength(in header: String) -> Int? {
        var found: String?
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length"
            else { continue }
            if found != nil { return Int.min }
            found = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let raw = found else { return nil }
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return Int.min }
        if raw.count > 1 && raw.first == "0" { return Int.min }
        return Int(raw) ?? Int.min
    }
}

public enum ScriptingDocumentRoute: Equatable, Sendable {
    case info, stretch, colormap, scale, zscale, regionsGet, regionsPost, regionsClear
}

public enum ScriptingHTTPRoute: Equatable, Sendable {
    case status, open, quit
    /// A nil route preserves the old document-existence check before the 404.
    case document(id: Int, route: ScriptingDocumentRoute?)
    case failure(ScriptingHTTPFailure)
}

public enum ScriptingRouteTarget: Equatable, Sendable {
    case status, open, quit
    case document(ScriptingDocumentRoute)
}

public struct ScriptingRouteDescriptor: Equatable, Sendable {
    public let method: String
    public let path: String
    public let summary: String
    public let target: ScriptingRouteTarget

    public init(method: String, path: String, summary: String, target: ScriptingRouteTarget) {
        self.method = method
        self.path = path
        self.summary = summary
        self.target = target
    }
}

/// Resolves the existing 11 HTTP routes without referring to AppKit or sockets.
public enum ScriptingHTTPRouter {
    public static func finiteLevel(_ value: Double) -> Float? {
        let level = Float(value)
        return level.isFinite ? level : nil
    }

    public static let routeTable: [ScriptingRouteDescriptor] = [
        .init(method: "GET", path: "/status", summary: "→ {version, beta, open: [{id, path}]}", target: .status),
        .init(method: "POST", path: "/open", summary: "body: {path, stretch?, colormap?, vmin?, vmax?, zscale?} → {id}", target: .open),
        .init(method: "GET", path: "/document/<id>/info", summary: "→ document view state", target: .document(.info)),
        .init(method: "POST", path: "/document/<id>/stretch", summary: "body: {name}", target: .document(.stretch)),
        .init(method: "POST", path: "/document/<id>/colormap", summary: "body: {name}", target: .document(.colormap)),
        .init(method: "POST", path: "/document/<id>/scale", summary: "body: {vmin, vmax}", target: .document(.scale)),
        .init(method: "POST", path: "/document/<id>/zscale", summary: "→ {ok}", target: .document(.zscale)),
        .init(method: "GET", path: "/document/<id>/regions", summary: "→ .reg text", target: .document(.regionsGet)),
        .init(method: "POST", path: "/document/<id>/regions", summary: "body: .reg text", target: .document(.regionsPost)),
        .init(method: "POST", path: "/document/<id>/regions/clear", summary: "→ {ok}", target: .document(.regionsClear)),
        .init(method: "POST", path: "/quit", summary: "→ {ok}", target: .quit),
    ]

    public static func resolve(_ request: ScriptingHTTPRequest) -> ScriptingHTTPRoute {
        let lines = request.header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return .failure(.init(status: 400, message: "bad request"))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(.init(status: 400, message: "bad request line"))
        }
        return resolve(method: String(parts[0]), path: String(parts[1]))
    }

    public static func resolve(method: String, path: String) -> ScriptingHTTPRoute {
        if let descriptor = routeTable.first(where: { $0.method == method && $0.path == path }) {
            switch descriptor.target {
            case .status: return .status
            case .open: return .open
            case .quit: return .quit
            case .document: break
            }
        }
        if path.hasPrefix("/document/") {
            let stripped = String(path.dropFirst("/document/".count))
            let segments = stripped.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            guard let id = Int(segments[0]) else {
                return .failure(.init(status: 404, message: "bad id"))
            }
            let subpath = segments.dropFirst().joined(separator: "/")
            let templatePath = "/document/<id>/" + subpath
            let route = routeTable.first(where: { $0.method == method && $0.path == templatePath })
                .flatMap { descriptor -> ScriptingDocumentRoute? in
                    if case .document(let documentRoute) = descriptor.target { return documentRoute }
                    return nil
                }
            return .document(id: id, route: route)
        }
        return .failure(.init(status: 404, message: "no route"))
    }

    /// Decodes the four body-based mutations and the zscale command. The Mac
    /// adapter performs the returned command with origin .script.
    public static func command(for route: ScriptingDocumentRoute, body: Data)
        -> Result<SessionCommand, ScriptingHTTPFailure> {
        switch route {
        case .stretch:
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let name = object["name"] as? String,
                  let stretch = ImageStretch(rawValue: name) else {
                return .failure(.init(status: 400, message: "expected {name: <stretch>}"))
            }
            return .success(.setStretch(stretch))
        case .colormap:
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let name = object["name"] as? String,
                  let colormap = ColorMap(rawValue: name) else {
                return .failure(.init(status: 400, message: "expected {name: <colormap>}"))
            }
            return .success(.setColormap(colormap))
        case .scale:
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let vmin = object["vmin"] as? Double,
                  let vmax = object["vmax"] as? Double,
                  let minimum = finiteLevel(vmin),
                  let maximum = finiteLevel(vmax) else {
                return .failure(.init(status: 400, message: "expected {vmin, vmax}"))
            }
            return .success(.setLevels(min: minimum, max: maximum))
        case .zscale:
            return .success(.applyScalePreset(.zscale))
        default:
            return .failure(.init(status: 404, message: "no route"))
        }
    }
}
