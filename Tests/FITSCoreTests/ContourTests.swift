import XCTest
@testable import FITSCore

final class ContourTests: XCTestCase {
    func testCancellationIsCheckedBetweenContourRows() {
        enum Abort: Error { case cancelled }
        let values = [Double](repeating: 0, count: 9)
        var checks = 0
        XCTAssertThrowsError(try Contours.segmentsCheckingCancellation(
            values: values, width: 3, height: 3, levels: [1],
            checkCancellation: {
                checks += 1
                if checks == 3 { throw Abort.cancelled }
            }
        ))
        XCTAssertEqual(checks, 3)
    }

    /// Trivial 2×2 patch with one corner above the level → produces a single short segment.
    func testSinglePixelTriangleProducesOneSegment() {
        // 2×2 grid: bottom-left=2, others=0 (row-major, j=0 is bottom row).
        // Level=1 cuts the diagonal at midpoints of bottom and left edges.
        let values: [Double] = [
            2, 0,   // j=0 (bottom): bl=2, br=0
            0, 0,   // j=1 (top):    tl=0, tr=0
        ]
        let segments = Contours.segments(values: values, width: 2, height: 2, level: 1)
        XCTAssertEqual(segments.count, 1)
        let s = segments[0]
        // Bottom edge midpoint (0.5, 0) and left edge midpoint (0, 0.5)
        let lo = SIMD2(min(s.a.x, s.b.x), min(s.a.y, s.b.y))
        let hi = SIMD2(max(s.a.x, s.b.x), max(s.a.y, s.b.y))
        XCTAssertEqual(lo.x, 0,   accuracy: 1e-9)
        XCTAssertEqual(lo.y, 0,   accuracy: 1e-9)
        XCTAssertEqual(hi.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(hi.y, 0.5, accuracy: 1e-9)
    }

    func testUniformImageProducesNoSegments() {
        let values = [Double](repeating: 5, count: 9)
        let segments = Contours.segments(values: values, width: 3, height: 3, level: 5)
        XCTAssertEqual(segments.count, 0)
    }

    func testLevelAboveAllValuesProducesNoSegments() {
        let values: [Double] = [1, 2, 3, 4]
        let segments = Contours.segments(values: values, width: 2, height: 2, level: 100)
        XCTAssertEqual(segments.count, 0)
    }

    func testMultipleLevelsProducesUnionOfSegments() {
        // 3×3 grid, two distinct level sets crossing different cells.
        let values: [Double] = [
            0, 0, 0,
            0, 5, 0,
            0, 0, 0,
        ]
        let s1 = Contours.segments(values: values, width: 3, height: 3, level: 1)
        let s2 = Contours.segments(values: values, width: 3, height: 3, level: 3)
        XCTAssertGreaterThan(s1.count, 0)
        XCTAssertGreaterThan(s2.count, 0)
        // Higher level → contour shrinks inward → typically fewer segments.
        XCTAssertLessThanOrEqual(s2.count, s1.count)
    }

    func testNaNCellsSkipped() {
        let values: [Double] = [
            .nan, 0,
            0,    0,
        ]
        // Should not crash, may produce zero segments since NaN corner disqualifies the cell.
        let s = Contours.segments(values: values, width: 2, height: 2, level: 0.5)
        XCTAssertEqual(s.count, 0)
    }

    func testSegmentsAtMultipleLevelsBuildsLeveledSet() {
        let values: [Double] = [
            0, 0, 0,
            0, 10, 0,
            0, 0, 0,
        ]
        let levels = [1.0, 3.0, 7.0]
        let leveled = Contours.segments(values: values, width: 3, height: 3, levels: levels)
        XCTAssertEqual(leveled.count, levels.count)
        XCTAssertEqual(leveled.map(\.level), levels)
    }
}
