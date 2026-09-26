import Foundation
#if canImport(simd)
import simd
#endif

/// Pure helpers for turning user mouse interactions into `Region` values.
///
/// All inputs are 0-based image-pixel coordinates; outputs use FITS-standard 1-based
/// convention so they round-trip cleanly through `.reg` files.
public enum RegionDrawing {
    public static func makeCircle(
        startImage start: SIMD2<Double>,
        endImage end: SIMD2<Double>
    ) -> Region {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let radius = (dx * dx + dy * dy).squareRoot()
        return Region(
            shape: .circle(
                center: .init(x: start.x + 1, y: start.y + 1),
                radius: .init(value: radius, unit: .pixel)
            ),
            frame: .image
        )
    }

    /// Bounding-box drag → centered, axis-aligned box. Reverse drags are normalized.
    public static func makeBox(
        startImage start: SIMD2<Double>,
        endImage end: SIMD2<Double>
    ) -> Region {
        let cx = (start.x + end.x) / 2
        let cy = (start.y + end.y) / 2
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)
        return Region(
            shape: .box(
                center: .init(x: cx + 1, y: cy + 1),
                width:  .init(value: w, unit: .pixel),
                height: .init(value: h, unit: .pixel),
                angle: 0
            ),
            frame: .image
        )
    }

    /// Bounding-box drag → centered, axis-aligned ellipse with rx = w/2, ry = h/2.
    public static func makeEllipse(
        startImage start: SIMD2<Double>,
        endImage end: SIMD2<Double>
    ) -> Region {
        let cx = (start.x + end.x) / 2
        let cy = (start.y + end.y) / 2
        let rx = abs(end.x - start.x) / 2
        let ry = abs(end.y - start.y) / 2
        return Region(
            shape: .ellipse(
                center: .init(x: cx + 1, y: cy + 1),
                rx: .init(value: rx, unit: .pixel),
                ry: .init(value: ry, unit: .pixel),
                angle: 0
            ),
            frame: .image
        )
    }

    /// Center-to-edge drag → annulus with outerRadius = drag distance,
    /// innerRadius = outerRadius/2. The user can fine-tune in the inspector later.
    public static func makeAnnulus(
        startImage start: SIMD2<Double>,
        endImage end: SIMD2<Double>
    ) -> Region {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let outer = (dx * dx + dy * dy).squareRoot()
        let inner = outer / 2
        return Region(
            shape: .annulus(
                center: .init(x: start.x + 1, y: start.y + 1),
                innerRadius: .init(value: inner, unit: .pixel),
                outerRadius: .init(value: outer, unit: .pixel)
            ),
            frame: .image
        )
    }

    /// Polygon from N image-space vertices.
    public static func makePolygon(_ vertices: [SIMD2<Double>]) -> Region {
        Region(
            shape: .polygon(points: vertices.map { .init(x: $0.x + 1, y: $0.y + 1) }),
            frame: .image
        )
    }
}
