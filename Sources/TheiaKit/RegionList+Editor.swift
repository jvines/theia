import Foundation
import FITSCore

extension RegionList {
    public enum Field: Sendable, Equatable {
        case centerX, centerY, radius, width, height, angle, rx, ry
        case innerRadius, outerRadius
        case vertexX(Int), vertexY(Int)
        case pointX, pointY
    }

    public enum EditorRow: Sendable, Equatable {
        case coordinates(label: String, x: Double, y: Double, xField: Field, yField: Field)
        case distance(label: String, value: Double, unit: Region.Distance.Unit, field: Field)
        case angle(value: Double, field: Field)
    }

    public enum Attribute: Sendable {
        case color, label, tag

        fileprivate var key: String {
            switch self {
            case .color: "color"
            case .label: "text"
            case .tag: "tag"
            }
        }
    }

    public static let colors = ["green", "red", "yellow", "cyan", "magenta", "blue", "white", "black"]
    public static let defaultColor = "green"

    public static func color(_ raw: String?) -> String {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return colors.contains(name) ? name : defaultColor
    }

    public static func attribute(_ attribute: Attribute, in region: Region) -> String {
        let value = region.attributes[attribute.key]
        return value ?? (attribute == .color ? defaultColor : "")
    }

    public static func settingAttribute(_ attribute: Attribute, to value: String, in region: Region) -> Region {
        var attributes = region.attributes
        if attribute == .color {
            attributes[attribute.key] = color(value)
        } else if value.isEmpty {
            attributes.removeValue(forKey: attribute.key)
        } else {
            attributes[attribute.key] = value
        }
        return Region(shape: region.shape, frame: region.frame, attributes: attributes)
    }

    public static func editorRows(for region: Region) -> [EditorRow] {
        switch region.shape {
        case .circle(let center, let radius):
            return [centerRow(center), .distance(label: "radius", value: radius.value, unit: radius.unit, field: .radius)]
        case .box(let center, let width, let height, let angle):
            return [centerRow(center),
                    .distance(label: "width", value: width.value, unit: width.unit, field: .width),
                    .distance(label: "height", value: height.value, unit: height.unit, field: .height),
                    .angle(value: angle, field: .angle)]
        case .ellipse(let center, let rx, let ry, let angle):
            return [centerRow(center),
                    .distance(label: "rx", value: rx.value, unit: rx.unit, field: .rx),
                    .distance(label: "ry", value: ry.value, unit: ry.unit, field: .ry),
                    .angle(value: angle, field: .angle)]
        case .annulus(let center, let inner, let outer):
            return [centerRow(center),
                    .distance(label: "inner", value: inner.value, unit: inner.unit, field: .innerRadius),
                    .distance(label: "outer", value: outer.value, unit: outer.unit, field: .outerRadius)]
        case .polygon(let points):
            return points.enumerated().map { index, point in
                .coordinates(label: "v\(index)", x: point.x, y: point.y,
                             xField: .vertexX(index), yField: .vertexY(index))
            }
        case .point(let point):
            return [.coordinates(label: "pos", x: point.x, y: point.y, xField: .pointX, yField: .pointY)]
        }
    }

    public static func unitLabel(_ unit: Region.Distance.Unit) -> String {
        switch unit {
        case .pixel: "px"
        case .arcsecond: "″"
        case .arcminute: "′"
        case .degree: "°"
        }
    }

    public static func editorNumber(_ number: Double) -> String {
        if number == number.rounded() && abs(number) < 1e9 {
            return String(format: "%.0f", number)
        }
        return String(format: "%.4g", number)
    }

    public static func summary(for region: Region) -> String {
        func fmt(_ number: Double) -> String { String(format: "%.1f", number) }
        switch region.shape {
        case .circle(let center, let radius):
            return "circle (\(fmt(center.x)), \(fmt(center.y))) r=\(fmt(radius.value))"
        case .box(let center, let width, let height, let angle):
            return "box (\(fmt(center.x)), \(fmt(center.y))) \(fmt(width.value))×\(fmt(height.value))∠\(fmt(angle))"
        case .ellipse(let center, let rx, let ry, let angle):
            return "ellipse (\(fmt(center.x)), \(fmt(center.y))) rx=\(fmt(rx.value)) ry=\(fmt(ry.value))∠\(fmt(angle))"
        case .annulus(let center, let inner, let outer):
            return "annulus (\(fmt(center.x)), \(fmt(center.y))) \(fmt(inner.value))…\(fmt(outer.value))"
        case .polygon(let points):
            return "polygon (\(points.count) verts)"
        case .point(let point):
            return "point (\(fmt(point.x)), \(fmt(point.y)))"
        }
    }

    /// Return nil for a field that does not belong to this shape or vertex list.
    public static func setting(_ field: Field, to value: Double, in region: Region) -> Region? {
        let shape: Region.Shape
        switch region.shape {
        case .circle(let center, let radius):
            if let center = settingCenter(field, to: value, in: center) {
                shape = .circle(center: center, radius: radius)
            } else if field == .radius {
                shape = .circle(center: center, radius: distance(radius, value: value))
            } else { return nil }
        case .box(let center, let width, let height, let angle):
            if let center = settingCenter(field, to: value, in: center) {
                shape = .box(center: center, width: width, height: height, angle: angle)
            } else if field == .width {
                shape = .box(center: center, width: distance(width, value: value), height: height, angle: angle)
            } else if field == .height {
                shape = .box(center: center, width: width, height: distance(height, value: value), angle: angle)
            } else if field == .angle {
                shape = .box(center: center, width: width, height: height, angle: value)
            } else { return nil }
        case .ellipse(let center, let rx, let ry, let angle):
            if let center = settingCenter(field, to: value, in: center) {
                shape = .ellipse(center: center, rx: rx, ry: ry, angle: angle)
            } else if field == .rx {
                shape = .ellipse(center: center, rx: distance(rx, value: value), ry: ry, angle: angle)
            } else if field == .ry {
                shape = .ellipse(center: center, rx: rx, ry: distance(ry, value: value), angle: angle)
            } else if field == .angle {
                shape = .ellipse(center: center, rx: rx, ry: ry, angle: value)
            } else { return nil }
        case .annulus(let center, let inner, let outer):
            if let center = settingCenter(field, to: value, in: center) {
                shape = .annulus(center: center, innerRadius: inner, outerRadius: outer)
            } else if field == .innerRadius {
                shape = .annulus(center: center, innerRadius: distance(inner, value: value), outerRadius: outer)
            } else if field == .outerRadius {
                shape = .annulus(center: center, innerRadius: inner, outerRadius: distance(outer, value: value))
            } else { return nil }
        case .polygon(var points):
            switch field {
            case .vertexX(let index) where points.indices.contains(index):
                points[index] = .init(x: value, y: points[index].y)
            case .vertexY(let index) where points.indices.contains(index):
                points[index] = .init(x: points[index].x, y: value)
            default: return nil
            }
            shape = .polygon(points: points)
        case .point(let point):
            switch field {
            case .pointX: shape = .point(.init(x: value, y: point.y))
            case .pointY: shape = .point(.init(x: point.x, y: value))
            default: return nil
            }
        }
        return Region(shape: shape, frame: region.frame, attributes: region.attributes)
    }

    private static func centerRow(_ point: Region.Point) -> EditorRow {
        .coordinates(label: "center", x: point.x, y: point.y, xField: .centerX, yField: .centerY)
    }

    private static func settingCenter(_ field: Field, to value: Double, in point: Region.Point) -> Region.Point? {
        switch field {
        case .centerX: .init(x: value, y: point.y)
        case .centerY: .init(x: point.x, y: value)
        default: nil
        }
    }

    private static func distance(_ old: Region.Distance, value: Double) -> Region.Distance {
        .init(value: value, unit: old.unit)
    }
}
