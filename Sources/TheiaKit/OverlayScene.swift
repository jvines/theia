import Foundation
import FITSCore

public struct OverlaySegment: Sendable, Equatable {
    public let from: SIMD2<Double>
    public let to: SIMD2<Double>

    public init(from: SIMD2<Double>, to: SIMD2<Double>) {
        self.from = from
        self.to = to
    }
}

public enum OverlayFont: Sendable, Equatable {
    case monospaced
    case systemSemibold
    case systemMedium
}

public enum OverlayTextAnchor: Sendable, Equatable {
    case center
    case topTrailing
    case trailing
    case bottomTrailing
}

public struct OverlayTextBackground: Sendable, Equatable {
    public let color: OverlayColor
    public let opacity: Double
    public let cornerRadius: Double
    public let horizontalPadding: Double
    public let verticalPadding: Double

    public init(color: OverlayColor, opacity: Double, cornerRadius: Double,
                horizontalPadding: Double, verticalPadding: Double) {
        self.color = color
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }
}

/// Shapes in view points, ready for a platform's drawing API.
public enum OverlayPrimitive: Sendable, Equatable {
    case segments([OverlaySegment], stroke: OverlayColor, opacity: Double,
                  lineWidth: Double, dash: [Double])
    case path(points: [SIMD2<Double>], closed: Bool, stroke: OverlayColor,
              opacity: Double, lineWidth: Double)
    case ellipse(center: SIMD2<Double>, radiusX: Double, radiusY: Double,
                 stroke: OverlayColor, opacity: Double, lineWidth: Double, dash: [Double] = [])
    case text(String, at: SIMD2<Double>, color: OverlayColor, size: Double,
              opacity: Double, font: OverlayFont = .monospaced,
              anchor: OverlayTextAnchor = .center,
              background: OverlayTextBackground? = nil)
    case handle(center: SIMD2<Double>, radius: Double, color: OverlayColor)
}

/// Caches region geometry in image pixels and maps it for each view transform.
@MainActor public final class OverlayScene {
    private enum Shape {
        case path([SIMD2<Double>], closed: Bool)
        case ellipse(center: SIMD2<Double>, rx: Double, ry: Double)
        case point(SIMD2<Double>)
    }

    private struct RegionGeometry {
        let shapes: [Shape]
        let labelAnchor: SIMD2<Double>?
        let handles: [SIMD2<Double>]
    }

    private var cachedRegions: [Region]?
    private var cachedWCSKey: WCSGeometryKey?
    private var cachedGeometry: [RegionGeometry?] = []
    private(set) var regionGenerationCount = 0

    public init() {}

    public func regionPrimitives(_ regions: [Region], selectedIndex: Int?,
                                 preview: Region? = nil, wcs: WCS?,
                                 mapping: ViewMapping) -> [OverlayPrimitive] {
        let wcsKey = wcs.map { WCSGeometryKey(wcs: $0, width: 0, height: 0) }
        if cachedRegions != regions || cachedWCSKey != wcsKey {
            cachedGeometry = regions.map { geometry(for: $0, wcs: wcs) }
            cachedRegions = regions
            cachedWCSKey = wcsKey
            regionGenerationCount += 1
        }
        var primitives: [OverlayPrimitive] = []
        for (index, region) in regions.enumerated() {
            guard let geometry = cachedGeometry[index] else { continue }
            append(geometry, for: region, selected: selectedIndex == index,
                   mapping: mapping, to: &primitives)
        }
        if let preview, let geometry = geometry(for: preview, wcs: wcs) {
            append(geometry, for: preview, selected: false, mapping: mapping, to: &primitives)
        }
        return primitives
    }

    private func append(_ geometry: RegionGeometry, for region: Region, selected: Bool,
                        mapping: ViewMapping, to output: inout [OverlayPrimitive]) {
        let color = selected ? OverlayColor(red: 1, green: 1, blue: 0)
                             : (OverlayColor.parse(region.attributes["color"]) ?? .defaultRegion)
        let opacity = selected ? 1.0 : 0.85
        let width = selected ? 2.4 : 1.2
        for shape in geometry.shapes {
            switch shape {
            case .path(let points, let closed):
                output.append(.path(points: points.map(mapping.imageToView), closed: closed,
                                    stroke: color, opacity: opacity, lineWidth: width))
            case .ellipse(let center, let rx, let ry):
                output.append(.ellipse(center: mapping.imageToView(center),
                                       radiusX: rx * mapping.transform.scale,
                                       radiusY: ry * mapping.transform.scale,
                                       stroke: color, opacity: opacity, lineWidth: width))
            case .point(let center):
                output.append(.ellipse(center: mapping.imageToView(center), radiusX: 3, radiusY: 3,
                                       stroke: color, opacity: opacity, lineWidth: width))
            }
        }
        if let label = region.attributes["text"], !label.isEmpty,
           let anchor = geometry.labelAnchor {
            let mapped = mapping.imageToView(anchor)
            output.append(.text(label, at: SIMD2(mapped.x, mapped.y - 10),
                                color: color, size: 11, opacity: opacity))
        }
        if selected {
            for point in geometry.handles {
                output.append(.handle(center: mapping.imageToView(point), radius: 3, color: color))
            }
        }
    }

    private func geometry(for region: Region, wcs: WCS?) -> RegionGeometry? {
        func center(_ point: Region.Point) -> SIMD2<Double>? {
            imageCenter(of: point, frame: region.frame, wcs: wcs)
        }
        func length(_ distance: Region.Distance) -> Double? {
            guard let value = pixelLength(distance, frame: region.frame, wcs: wcs),
                  value.isFinite, value >= 0 else { return nil }
            return value
        }
        switch region.shape {
        case .circle(let point, let radius):
            guard let c = center(point), let r = length(radius) else { return nil }
            return RegionGeometry(shapes: [.ellipse(center: c, rx: r, ry: r)],
                                  labelAnchor: c, handles: [c, SIMD2(c.x + r, c.y)])
        case .annulus(let point, let inner, let outer):
            guard let c = center(point), let rIn = length(inner), let rOut = length(outer) else { return nil }
            return RegionGeometry(shapes: [.ellipse(center: c, rx: rOut, ry: rOut),
                                           .ellipse(center: c, rx: rIn, ry: rIn)],
                                  labelAnchor: c, handles: [c, SIMD2(c.x + rIn, c.y), SIMD2(c.x + rOut, c.y)])
        case .box(let point, let width, let height, let angle):
            guard let c = center(point), let w = length(width), let h = length(height),
                  angle.isFinite else { return nil }
            let theta = angle * .pi / 180
            let cosT = cos(theta), sinT = sin(theta)
            let corners = [SIMD2(-w / 2, -h / 2), SIMD2(w / 2, -h / 2),
                           SIMD2(w / 2, h / 2), SIMD2(-w / 2, h / 2)]
                .map { local in
                    SIMD2(c.x + local.x * cosT - local.y * sinT,
                          c.y + local.x * sinT + local.y * cosT)
                }
            return RegionGeometry(shapes: [.path(corners, closed: true)],
                                  labelAnchor: c, handles: corners + [c])
        case .ellipse(let point, let rx, let ry, let angle):
            guard let c = center(point), let x = length(rx), let y = length(ry),
                  angle.isFinite else { return nil }
            let theta = angle * .pi / 180
            let cosT = cos(theta), sinT = sin(theta)
            let points = (0..<64).map { step -> SIMD2<Double> in
                let a = Double(step) / 64 * 2 * .pi
                let lx = x * cos(a), ly = y * sin(a)
                return SIMD2(c.x + lx * cosT - ly * sinT,
                             c.y + lx * sinT + ly * cosT)
            }
            let xHandle = SIMD2(c.x + x * cosT, c.y + x * sinT)
            let yHandle = SIMD2(c.x - y * sinT, c.y + y * cosT)
            return RegionGeometry(shapes: [.path(points, closed: true)],
                                  labelAnchor: c, handles: [c, xHandle, yHandle])
        case .polygon(let vertices):
            let points = vertices.compactMap(center)
            guard !points.isEmpty, points.count == vertices.count else { return nil }
            return RegionGeometry(shapes: [.path(points, closed: true)],
                                  labelAnchor: points[0], handles: points)
        case .point(let point):
            guard let c = center(point) else { return nil }
            return RegionGeometry(shapes: [.point(c)], labelAnchor: c, handles: [c])
        }
    }
}
