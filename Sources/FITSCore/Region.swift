import Foundation

/// A region annotation (.reg-compatible). Mirrors the subset of the `.reg`
/// format that real-world astronomy tooling uses heavily.
public struct Region: Sendable, Equatable, Codable {
    public enum Frame: String, Sendable, Equatable, Codable {
        case image
        case fk5
        case icrs
        case j2000
        case galactic
    }

    public struct Point: Sendable, Equatable, Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x; self.y = y
        }
    }

    public struct Distance: Sendable, Equatable, Codable {
        public enum Unit: String, Sendable, Equatable, Codable {
            case pixel
            case degree
            case arcminute
            case arcsecond
        }
        public let value: Double
        public let unit: Unit
        public init(value: Double, unit: Unit) {
            self.value = value; self.unit = unit
        }
    }

    public enum Shape: Sendable, Equatable, Codable {
        case circle(center: Point, radius: Distance)
        case box(center: Point, width: Distance, height: Distance, angle: Double)
        case ellipse(center: Point, rx: Distance, ry: Distance, angle: Double)
        case polygon(points: [Point])
        case annulus(center: Point, innerRadius: Distance, outerRadius: Distance)
        case point(Point)
    }

    public let shape: Shape
    public let frame: Frame
    public let attributes: [String: String]

    public init(shape: Shape, frame: Frame, attributes: [String: String] = [:]) {
        self.shape = shape
        self.frame = frame
        self.attributes = attributes
    }
}

public enum RegionError: Error {
    case malformed(String)
}

extension Region {
    /// Standard even-odd ray cast. `vertices` are in `.reg` 1-based coordinates;
    /// `point` is in 0-based image coordinates. Single source of truth shared by
    /// `Photometry` and the interactive `RegionEdit` hit-testing.
    public static func pointInPolygon(_ point: SIMD2<Double>, vertices: [Point]) -> Bool {
        guard vertices.count >= 3 else { return false }
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let xi = vertices[i].x - 1, yi = vertices[i].y - 1
            let xj = vertices[j].x - 1, yj = vertices[j].y - 1
            let intersects = ((yi > point.y) != (yj > point.y)) &&
                (point.x < (xj - xi) * (point.y - yi) / (yj - yi + 1e-30) + xi)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }
}

public enum RegionFile {
    public static func format(_ regions: [Region]) -> String {
        var out: [String] = []
        var currentFrame: Region.Frame? = nil
        for r in regions {
            if currentFrame != r.frame {
                out.append(r.frame.rawValue)
                currentFrame = r.frame
            }
            out.append(formatRegion(r))
        }
        return out.joined(separator: "\n")
    }

    private static func formatRegion(_ r: Region) -> String {
        let body: String
        switch r.shape {
        case .circle(let c, let radius):
            body = "circle(\(num(c.x)), \(num(c.y)), \(distance(radius)))"
        case .box(let c, let w, let h, let angle):
            body = "box(\(num(c.x)), \(num(c.y)), \(distance(w)), \(distance(h)), \(num(angle)))"
        case .ellipse(let c, let rx, let ry, let angle):
            body = "ellipse(\(num(c.x)), \(num(c.y)), \(distance(rx)), \(distance(ry)), \(num(angle)))"
        case .polygon(let pts):
            let coords = pts.flatMap { [num($0.x), num($0.y)] }.joined(separator: ", ")
            body = "polygon(\(coords))"
        case .annulus(let c, let rIn, let rOut):
            body = "annulus(\(num(c.x)), \(num(c.y)), \(distance(rIn)), \(distance(rOut)))"
        case .point(let p):
            body = "point(\(num(p.x)), \(num(p.y)))"
        }
        if r.attributes.isEmpty { return body }
        let attrs = r.attributes
            .sorted(by: { $0.key < $1.key })
            .map { k, v in v.contains(" ") ? "\(k)={\(v)}" : "\(k)=\(v)" }
            .joined(separator: " ")
        return "\(body) # \(attrs)"
    }

    private static func num(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(format: "%g", d)
        }
        return String(d)
    }

    private static func distance(_ d: Region.Distance) -> String {
        let v = num(d.value)
        switch d.unit {
        case .pixel: return v
        case .arcsecond: return "\(v)\""
        case .arcminute: return "\(v)'"
        case .degree: return "\(v)d"
        }
    }

    public static func parse(_ text: String) throws -> [Region] {
        var frame: Region.Frame = .image
        var out: [Region] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("global") {
                continue
            }
            if let f = Region.Frame(rawValue: line.lowercased()) {
                frame = f
                continue
            }
            // Recognised DS9 coordinate systems we don't model as a distinct frame
            // (physical, wcs, detector, …). Ignore them rather than treating the
            // bare word as a malformed shape — otherwise real .reg files fail.
            if isCoordinateDirective(line.lowercased()) {
                continue
            }
            out.append(try parseShapeLine(line, frame: frame))
        }
        return out
    }

    /// True for a bare DS9 coordinate-system line we accept but don't map to a
    /// `Region.Frame`. Anything else without a `(...)` body is treated as a
    /// malformed shape (thrown), so corrupt input can't silently vanish.
    private static func isCoordinateDirective(_ token: String) -> Bool {
        switch token {
        case "image", "physical", "detector", "amplifier", "linear",
             "fk4", "fk5", "icrs", "j2000", "b1950", "galactic", "ecliptic", "wcs":
            return true
        default:
            // wcsa … wcsz (alternate WCS solutions)
            return token.count == 4 && token.hasPrefix("wcs") && (token.last?.isLetter ?? false)
        }
    }

    private static func parseShapeLine(_ line: String, frame: Region.Frame) throws -> Region {
        // Split off attribute comment after `#`.
        let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let shapeText = parts[0].trimmingCharacters(in: .whitespaces)
        let attrText = parts.count > 1 ? String(parts[1]) : ""
        // A shape must carry a `(...)` argument body. A line without one that
        // reached here is neither a comment/global/frame nor a known coordinate
        // directive — it's corrupt, so throw instead of silently dropping it.
        guard let openParen = shapeText.firstIndex(of: "("),
              let closeParen = shapeText.lastIndex(of: ")") else {
            throw RegionError.malformed(line)
        }
        let name = shapeText[..<openParen].trimmingCharacters(in: .whitespaces).lowercased()
        let argsText = shapeText[shapeText.index(after: openParen)..<closeParen]
        let args = argsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        let attributes = parseAttributes(attrText)
        let shape: Region.Shape
        switch name {
        case "circle":
            guard args.count == 3,
                  let x = Double(args[0]),
                  let y = Double(args[1]) else { throw RegionError.malformed(line) }
            shape = .circle(
                center: .init(x: x, y: y),
                radius: parseDistance(args[2])
            )
        case "box", "ellipse":
            let (center, d1, d2, angle) = try parseTwoAxisShape(args: args, line: line)
            shape = (name == "box")
                ? .box(center: center, width: d1, height: d2, angle: angle)
                : .ellipse(center: center, rx: d1, ry: d2, angle: angle)
        case "polygon":
            guard args.count.isMultiple(of: 2), args.count >= 6 else {
                throw RegionError.malformed(line)
            }
            var pts: [Region.Point] = []
            for i in stride(from: 0, to: args.count, by: 2) {
                guard let x = Double(args[i]), let y = Double(args[i + 1]) else {
                    throw RegionError.malformed(line)
                }
                pts.append(.init(x: x, y: y))
            }
            shape = .polygon(points: pts)
        case "annulus":
            guard args.count == 4,
                  let x = Double(args[0]), let y = Double(args[1]) else {
                throw RegionError.malformed(line)
            }
            shape = .annulus(
                center: .init(x: x, y: y),
                innerRadius: parseDistance(args[2]),
                outerRadius: parseDistance(args[3])
            )
        case "point":
            guard args.count == 2,
                  let x = Double(args[0]), let y = Double(args[1]) else {
                throw RegionError.malformed(line)
            }
            shape = .point(.init(x: x, y: y))
        default:
            throw RegionError.malformed("unknown shape \(name) in line: \(line)")
        }
        return Region(shape: shape, frame: frame, attributes: attributes)
    }

    /// Shared parser for `box(x, y, w, h, angle)` and `ellipse(x, y, rx, ry, angle)` —
    /// identical grammar, different semantics for the two axis values.
    private static func parseTwoAxisShape(args: [String], line: String) throws -> (Region.Point, Region.Distance, Region.Distance, Double) {
        guard args.count == 5,
              let x = Double(args[0]), let y = Double(args[1]),
              let angle = Double(args[4]) else { throw RegionError.malformed(line) }
        return (
            .init(x: x, y: y),
            parseDistance(args[2]),
            parseDistance(args[3]),
            angle
        )
    }

    private static func parseDistance(_ raw: String) -> Region.Distance {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("\"") {
            return .init(value: Double(s.dropLast()) ?? 0, unit: .arcsecond)
        }
        if s.hasSuffix("'") {
            return .init(value: Double(s.dropLast()) ?? 0, unit: .arcminute)
        }
        if s.hasSuffix("d") || s.hasSuffix("°") {
            return .init(value: Double(s.dropLast()) ?? 0, unit: .degree)
        }
        return .init(value: Double(s) ?? 0, unit: .pixel)
    }

    /// Parse `key=value` pairs (with optional `{braced text}`) from the comment
    /// segment following `#`.
    private static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var scanner = text[...]
        scanner = Substring(scanner.trimmingCharacters(in: .whitespaces))
        while let eq = scanner.firstIndex(of: "=") {
            let key = scanner[..<eq].trimmingCharacters(in: .whitespaces)
            var rest = scanner[scanner.index(after: eq)...]
            rest = Substring(rest.drop(while: { $0 == " " }))
            let value: String
            if rest.first == "{" {
                if let close = rest.firstIndex(of: "}") {
                    value = String(rest[rest.index(after: rest.startIndex)..<close])
                    scanner = rest[rest.index(after: close)...]
                } else {
                    value = String(rest.dropFirst())
                    scanner = ""
                }
            } else {
                let end = rest.firstIndex(where: { $0 == " " }) ?? rest.endIndex
                value = String(rest[..<end])
                scanner = rest[end...]
            }
            result[key] = value
            scanner = Substring(scanner.drop(while: { $0 == " " }))
            if scanner.isEmpty { break }
        }
        return result
    }
}
