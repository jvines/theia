import Foundation
#if canImport(simd)
import simd
#endif

/// Marching-squares contour extraction over a 2D scalar field.
///
/// Output coordinates are in **image pixel space** with y-up; integer corners (i, j)
/// hold the value at index `j * width + i`. Segments are line endpoints linearly
/// interpolated along cell edges.
public enum Contours {
    public struct Segment: Equatable, Sendable {
        public let a: SIMD2<Double>
        public let b: SIMD2<Double>
    }

    public struct LeveledSegments: Equatable, Sendable {
        public let level: Double
        public let segments: [Segment]
    }

    /// Single-level contour extraction. NaN cells are skipped silently.
    public static func segments(values: [Double], width: Int, height: Int, level: Double) -> [Segment] {
        try! segmentsCheckingCancellation(
            values: values, width: width, height: height, level: level,
            checkCancellation: {}
        )
    }

    /// Checks cancellation once per image row while extracting a single level.
    public static func segmentsCheckingCancellation(
        values: [Double], width: Int, height: Int, level: Double,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [Segment] {
        precondition(values.count == width * height, "values count must equal width * height")
        guard width >= 2, height >= 2 else { return [] }
        var out: [Segment] = []
        out.reserveCapacity(width * height / 8)
        for j in 0..<(height - 1) {
            try checkCancellation()
            for i in 0..<(width - 1) {
                // Corners — bl, br, tr, tl (counter-clockwise from bottom-left).
                let v00 = values[ j      * width +  i     ]   // bl
                let v10 = values[ j      * width + (i + 1)]   // br
                let v11 = values[(j + 1) * width + (i + 1)]   // tr
                let v01 = values[(j + 1) * width +  i     ]   // tl
                if v00.isNaN || v10.isNaN || v11.isNaN || v01.isNaN { continue }
                var code = 0
                if v00 >= level { code |= 1 }
                if v10 >= level { code |= 2 }
                if v11 >= level { code |= 4 }
                if v01 >= level { code |= 8 }
                if code == 0 || code == 15 { continue }

                // Edge interpolations (only the ones we use).
                let bx = Double(i) + interp(v00, v10, level)   // bottom: y = j
                let by = Double(j)
                let rx = Double(i + 1)                          // right: x = i+1
                let ry = Double(j) + interp(v10, v11, level)
                let tx = Double(i) + interp(v01, v11, level)   // top: y = j+1
                let ty = Double(j + 1)
                let lx = Double(i)                              // left: x = i
                let ly = Double(j) + interp(v00, v01, level)

                func emit(_ a: SIMD2<Double>, _ b: SIMD2<Double>) {
                    out.append(Segment(a: a, b: b))
                }

                switch code {
                case 1, 14:
                    emit(SIMD2(bx, by), SIMD2(lx, ly))
                case 2, 13:
                    emit(SIMD2(bx, by), SIMD2(rx, ry))
                case 3, 12:
                    emit(SIMD2(lx, ly), SIMD2(rx, ry))
                case 4, 11:
                    emit(SIMD2(rx, ry), SIMD2(tx, ty))
                case 5:
                    // Saddle: separate based on cell centre vs level.
                    let centre = (v00 + v10 + v11 + v01) / 4
                    if centre >= level {
                        emit(SIMD2(lx, ly), SIMD2(tx, ty))
                        emit(SIMD2(bx, by), SIMD2(rx, ry))
                    } else {
                        emit(SIMD2(lx, ly), SIMD2(bx, by))
                        emit(SIMD2(tx, ty), SIMD2(rx, ry))
                    }
                case 6, 9:
                    emit(SIMD2(bx, by), SIMD2(tx, ty))
                case 7, 8:
                    emit(SIMD2(lx, ly), SIMD2(tx, ty))
                case 10:
                    // Saddle: the other configuration.
                    let centre = (v00 + v10 + v11 + v01) / 4
                    if centre >= level {
                        emit(SIMD2(bx, by), SIMD2(rx, ry))
                        emit(SIMD2(lx, ly), SIMD2(tx, ty))
                    } else {
                        emit(SIMD2(bx, by), SIMD2(lx, ly))
                        emit(SIMD2(rx, ry), SIMD2(tx, ty))
                    }
                default: break
                }
            }
        }
        return out
    }

    /// Multi-level extraction.
    public static func segments(values: [Double], width: Int, height: Int, levels: [Double]) -> [LeveledSegments] {
        try! segmentsCheckingCancellation(
            values: values, width: width, height: height, levels: levels,
            checkCancellation: {}
        )
    }

    /// Checks cancellation between levels and between rows of each level.
    public static func segmentsCheckingCancellation(
        values: [Double], width: Int, height: Int, levels: [Double],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [LeveledSegments] {
        try levels.map { level in
            try checkCancellation()
            return LeveledSegments(level: level,
                            segments: try segmentsCheckingCancellation(
                                values: values, width: width, height: height,
                                level: level, checkCancellation: checkCancellation
                            ))
        }
    }

    /// Returns `t ∈ [0, 1]` such that `a + t * (b - a) == level`. Falls back to 0.5 if a == b.
    private static func interp(_ a: Double, _ b: Double, _ level: Double) -> Double {
        let denom = b - a
        if abs(denom) < 1e-30 { return 0.5 }
        let t = (level - a) / denom
        return max(0, min(1, t))
    }
}
