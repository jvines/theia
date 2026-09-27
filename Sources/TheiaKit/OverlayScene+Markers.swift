import Foundation
import FITSCore

extension OverlayScene {
    nonisolated public static func crosshair(at imagePoint: SIMD2<Double>?, mapping: ViewMapping) -> [OverlayPrimitive] {
        guard let imagePoint else { return [] }
        let center = mapping.imageToView(imagePoint)
        let yellow = OverlayColor(red: 1, green: 1, blue: 0)
        let r = 14.0
        return [
            .segments([
                .init(from: SIMD2(center.x - r, center.y), to: SIMD2(center.x + r, center.y)),
                .init(from: SIMD2(center.x, center.y - r), to: SIMD2(center.x, center.y + r)),
            ], stroke: yellow, opacity: 0.85, lineWidth: 1.2, dash: []),
            .ellipse(center: center, radiusX: 3, radiusY: 3,
                     stroke: yellow, opacity: 0.85, lineWidth: 1),
        ]
    }

    nonisolated public static func profile(_ geometry: ProfileGeometry?, mapping: ViewMapping) -> [OverlayPrimitive] {
        guard let geometry else { return [] }
        let gold = OverlayColor(red: 1, green: 0.85, blue: 0.30)
        func tick(_ center: SIMD2<Double>) -> OverlayPrimitive {
            let r = 6.0
            return .segments([
                .init(from: SIMD2(center.x - r, center.y), to: SIMD2(center.x + r, center.y)),
                .init(from: SIMD2(center.x, center.y - r), to: SIMD2(center.x, center.y + r)),
            ], stroke: gold, opacity: 1, lineWidth: 1.2, dash: [])
        }
        switch geometry {
        case .line(let from, let to):
            let a = mapping.imageToView(from), b = mapping.imageToView(to)
            let delta = to - from
            let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
            let middle = SIMD2((a.x + b.x) / 2, (a.y + b.y) / 2)
            return [
                .segments([.init(from: a, to: b)], stroke: gold,
                          opacity: 1, lineWidth: 1.5, dash: [4, 3]),
                tick(a), tick(b),
                .text(String(format: "%.1f px", length), at: middle,
                      color: gold, size: 10, opacity: 1),
            ]
        case .radial(let center, let maxRadius), .growth(let center, let maxRadius):
            let c = mapping.imageToView(center)
            let r = mapping.transform.scale * maxRadius
            let label: String
            if case .growth = geometry { label = String(format: "growth ≤ %.1f px", maxRadius) }
            else { label = String(format: "radial ≤ %.1f px", maxRadius) }
            return [
                tick(c),
                .ellipse(center: c, radiusX: r, radiusY: r,
                         stroke: gold, opacity: 1, lineWidth: 1.2, dash: [4, 3]),
                .text(label, at: SIMD2(c.x, c.y - r - 12),
                      color: gold, size: 10, opacity: 1),
            ]
        case .point(let point):
            let c = mapping.imageToView(point)
            return [
                tick(c),
                .text(String(format: "(%.1f, %.1f)", point.x, point.y),
                      at: SIMD2(c.x, c.y - 12), color: gold, size: 10, opacity: 1),
            ]
        }
    }

    nonisolated public static func contours(_ leveled: [Contours.LeveledSegments],
                                mapping: ViewMapping) -> [OverlayPrimitive] {
        let cyan = OverlayColor(red: 0, green: 1, blue: 1)
        return leveled.enumerated().compactMap { index, level in
            guard !level.segments.isEmpty else { return nil }
            let alpha = 0.45 + 0.55 * Double(index + 1) / Double(max(leveled.count, 1))
            let lines = level.segments.map { segment in
                OverlaySegment(from: mapping.imageToView(segment.a),
                               to: mapping.imageToView(segment.b))
            }
            return .segments(lines, stroke: cyan, opacity: alpha, lineWidth: 1, dash: [])
        }
    }
}
