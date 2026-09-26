import XCTest
#if canImport(simd)
import simd
#endif
@testable import FITSCore

final class RegionDrawingTests: XCTestCase {
    func testMakeCircleFromDragYieldsImageFrameCircle() {
        // start (10, 10) image-0-based; end (13, 14) → radius = 5 px
        let region = RegionDrawing.makeCircle(
            startImage: SIMD2(10, 10),
            endImage: SIMD2(13, 14)
        )
        XCTAssertEqual(region.frame, .image)
        XCTAssertEqual(region.shape, .circle(
            // Stored as 1-based FITS coords
            center: .init(x: 11, y: 11),
            radius: .init(value: 5, unit: .pixel)
        ))
    }

    func testMakeCircleZeroLengthDragHasZeroRadius() {
        let region = RegionDrawing.makeCircle(
            startImage: SIMD2(50, 50),
            endImage: SIMD2(50, 50)
        )
        if case .circle(_, let radius) = region.shape {
            XCTAssertEqual(radius.value, 0)
        } else {
            XCTFail("expected circle")
        }
    }

    // MARK: - Box

    func testMakeBoxFromDragYieldsCenteredRect() {
        // Drag from (10, 20) to (30, 50). Width=20 px, height=30 px.
        // Center is midpoint → (20, 35). FITS 1-based → (21, 36).
        let region = RegionDrawing.makeBox(
            startImage: SIMD2(10, 20),
            endImage: SIMD2(30, 50)
        )
        XCTAssertEqual(region.frame, .image)
        XCTAssertEqual(region.shape, .box(
            center: .init(x: 21, y: 36),
            width:  .init(value: 20, unit: .pixel),
            height: .init(value: 30, unit: .pixel),
            angle: 0
        ))
    }

    func testMakeBoxHandlesReverseDrag() {
        // Drag from (30, 50) back to (10, 20): same box, no negative width.
        let region = RegionDrawing.makeBox(
            startImage: SIMD2(30, 50),
            endImage: SIMD2(10, 20)
        )
        if case .box(_, let w, let h, _) = region.shape {
            XCTAssertEqual(w.value, 20)
            XCTAssertEqual(h.value, 30)
        } else {
            XCTFail("expected box")
        }
    }

    // MARK: - Ellipse

    func testMakeEllipseFromDragYieldsHalfDimensionRadii() {
        // Drag (10, 20) → (30, 50). Width=20, height=30 → rx=10, ry=15.
        let region = RegionDrawing.makeEllipse(
            startImage: SIMD2(10, 20),
            endImage: SIMD2(30, 50)
        )
        XCTAssertEqual(region.shape, .ellipse(
            center: .init(x: 21, y: 36),
            rx: .init(value: 10, unit: .pixel),
            ry: .init(value: 15, unit: .pixel),
            angle: 0
        ))
    }

    // MARK: - Annulus

    func testMakeAnnulusFromDragSetsOuterToDragRadiusInnerHalf() {
        // Drag center=(20, 30), edge=(23, 34) → radius = 5 → inner 2.5, outer 5.
        let region = RegionDrawing.makeAnnulus(
            startImage: SIMD2(20, 30),
            endImage: SIMD2(23, 34)
        )
        XCTAssertEqual(region.shape, .annulus(
            center: .init(x: 21, y: 31),
            innerRadius: .init(value: 2.5, unit: .pixel),
            outerRadius: .init(value: 5,   unit: .pixel)
        ))
    }
}
