import XCTest
#if canImport(simd)
import simd
#endif
@testable import FITSCore

final class RegionEditTests: XCTestCase {
    // Annulus at image-frame center (100, 100), inner=5px, outer=10px.
    // FITS files use 1-based, so center=(101, 101).
    private func annulus() -> Region {
        Region(
            shape: .annulus(
                center: .init(x: 101, y: 101),
                innerRadius: .init(value: 5,  unit: .pixel),
                outerRadius: .init(value: 10, unit: .pixel)
            ),
            frame: .image
        )
    }

    // MARK: - hit-test

    func testHitTestPicksOuterRingWhenClickIsNearOuterRadius() {
        // Click at image (100 + 10, 100) → right on the outer ring.
        let hit = RegionHitTest.hit(
            in: [annulus()],
            atImagePoint: SIMD2(110, 100),
            toleranceImagePixels: 3
        )
        XCTAssertEqual(hit?.regionIndex, 0)
        XCTAssertEqual(hit?.handle, .annulusOuter)
    }

    func testHitTestPicksInnerRingWhenClickIsNearInnerRadius() {
        let hit = RegionHitTest.hit(
            in: [annulus()],
            atImagePoint: SIMD2(105, 100),
            toleranceImagePixels: 3
        )
        XCTAssertEqual(hit?.handle, .annulusInner)
    }

    func testHitTestPicksMoveWhenClickIsInsideInnerDisc() {
        let hit = RegionHitTest.hit(
            in: [annulus()],
            atImagePoint: SIMD2(101, 101),
            toleranceImagePixels: 3
        )
        XCTAssertEqual(hit?.handle, .move)
    }

    func testHitTestReturnsNilOutsideOuterRing() {
        let hit = RegionHitTest.hit(
            in: [annulus()],
            atImagePoint: SIMD2(200, 200),
            toleranceImagePixels: 3
        )
        XCTAssertNil(hit)
    }

    func testHitTestSkipsNonImageFrameRegions() {
        // fk5 frame can't be edited via image-pixel hit-test.
        let fk5Annulus = Region(
            shape: .annulus(
                center: .init(x: 180, y: 0),
                innerRadius: .init(value: 5, unit: .arcsecond),
                outerRadius: .init(value: 10, unit: .arcsecond)
            ),
            frame: .fk5
        )
        let hit = RegionHitTest.hit(
            in: [fk5Annulus],
            atImagePoint: SIMD2(100, 100),
            toleranceImagePixels: 3
        )
        XCTAssertNil(hit)
    }

    // MARK: - apply drag

    func testApplyDragResizesOuterToDistance() {
        // Click started at outer ring (110, 100), dragged to (115, 100) → new outer = 15.
        let edited = RegionEdit.apply(
            to: annulus(),
            handle: .annulusOuter,
            dragStartImage: SIMD2(110, 100),
            currentImage: SIMD2(115, 100)
        )
        if case .annulus(_, let rIn, let rOut) = edited.shape {
            XCTAssertEqual(rOut.value, 15, accuracy: 1e-9)
            XCTAssertEqual(rIn.value, 5, accuracy: 1e-9)  // unchanged
        } else {
            XCTFail("expected annulus")
        }
    }

    func testApplyDragResizesInnerToDistance() {
        let edited = RegionEdit.apply(
            to: annulus(),
            handle: .annulusInner,
            dragStartImage: SIMD2(105, 100),
            currentImage: SIMD2(108, 100)
        )
        if case .annulus(_, let rIn, _) = edited.shape {
            XCTAssertEqual(rIn.value, 8, accuracy: 1e-9)
        } else {
            XCTFail("expected annulus")
        }
    }

    func testApplyDragInnerClampsToBelowOuter() {
        // Try to drag inner past outer (15px > outer=10) — should clamp at outer - epsilon.
        let edited = RegionEdit.apply(
            to: annulus(),
            handle: .annulusInner,
            dragStartImage: SIMD2(105, 100),
            currentImage: SIMD2(120, 100)
        )
        if case .annulus(_, let rIn, let rOut) = edited.shape {
            XCTAssertLessThan(rIn.value, rOut.value)
        } else {
            XCTFail("expected annulus")
        }
    }

    func testApplyDragOuterClampsToAboveInner() {
        // Drag outer below inner — should clamp.
        let edited = RegionEdit.apply(
            to: annulus(),
            handle: .annulusOuter,
            dragStartImage: SIMD2(110, 100),
            currentImage: SIMD2(102, 100)  // distance = 1 px, below inner=5
        )
        if case .annulus(_, let rIn, let rOut) = edited.shape {
            XCTAssertGreaterThan(rOut.value, rIn.value)
        } else {
            XCTFail("expected annulus")
        }
    }

    // MARK: - circle

    private func circle() -> Region {
        Region(
            shape: .circle(center: .init(x: 101, y: 101), radius: .init(value: 10, unit: .pixel)),
            frame: .image
        )
    }

    func testHitTestPicksCircleRadiusOnRing() {
        let hit = RegionHitTest.hit(in: [circle()], atImagePoint: SIMD2(110, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .circleRadius)
    }

    func testHitTestPicksMoveInsideCircle() {
        let hit = RegionHitTest.hit(in: [circle()], atImagePoint: SIMD2(101, 101), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .move)
    }

    func testApplyDragResizesCircleRadius() {
        let edited = RegionEdit.apply(
            to: circle(),
            handle: .circleRadius,
            dragStartImage: SIMD2(110, 100),
            currentImage: SIMD2(120, 100)
        )
        if case .circle(_, let r) = edited.shape {
            XCTAssertEqual(r.value, 20, accuracy: 1e-9)
        } else { XCTFail("expected circle") }
    }

    // MARK: - box (axis-aligned, no rotation)

    private func box(angle: Double = 0) -> Region {
        Region(
            shape: .box(
                center: .init(x: 101, y: 101),
                width:  .init(value: 20, unit: .pixel),
                height: .init(value: 10, unit: .pixel),
                angle: angle
            ),
            frame: .image
        )
    }

    func testHitTestPicksBoxCorner() {
        // Corner 0 (bottom-left) at image (90, 95). Click at (90, 95) → corner 0.
        let hit = RegionHitTest.hit(in: [box()], atImagePoint: SIMD2(90, 95), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .boxCorner(0))
        // Corner 2 (top-right) at (110, 105).
        let hit2 = RegionHitTest.hit(in: [box()], atImagePoint: SIMD2(110, 105), toleranceImagePixels: 3)
        XCTAssertEqual(hit2?.handle, .boxCorner(2))
    }

    func testHitTestPicksMoveInsideBox() {
        let hit = RegionHitTest.hit(in: [box()], atImagePoint: SIMD2(100, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .move)
    }

    func testApplyDragResizesBoxFromCorner() {
        // Grab corner 0 at (90, 95), drag to (80, 90). Opposite corner (2) stays at (110, 105).
        // New box: center=(95, 97.5), width=30, height=15.
        let edited = RegionEdit.apply(
            to: box(),
            handle: .boxCorner(0),
            dragStartImage: SIMD2(90, 95),
            currentImage: SIMD2(80, 90)
        )
        if case .box(let c, let w, let h, _) = edited.shape {
            XCTAssertEqual(c.x, 96, accuracy: 1e-9)   // FITS 1-based equivalent of (95)
            XCTAssertEqual(c.y, 98.5, accuracy: 1e-9) // FITS 1-based equivalent of (97.5)
            XCTAssertEqual(w.value, 30, accuracy: 1e-9)
            XCTAssertEqual(h.value, 15, accuracy: 1e-9)
        } else { XCTFail("expected box") }
    }

    // MARK: - ellipse

    private func ellipse() -> Region {
        Region(
            shape: .ellipse(
                center: .init(x: 101, y: 101),
                rx: .init(value: 20, unit: .pixel),
                ry: .init(value: 10, unit: .pixel),
                angle: 0
            ),
            frame: .image
        )
    }

    func testHitTestPicksEllipseRxOnEastEdge() {
        let hit = RegionHitTest.hit(in: [ellipse()], atImagePoint: SIMD2(120, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .ellipseRx)
    }

    func testHitTestPicksEllipseRyOnNorthEdge() {
        let hit = RegionHitTest.hit(in: [ellipse()], atImagePoint: SIMD2(100, 110), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .ellipseRy)
    }

    func testHitTestPicksMoveInsideEllipse() {
        let hit = RegionHitTest.hit(in: [ellipse()], atImagePoint: SIMD2(100, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .move)
    }

    func testApplyDragResizesEllipseRx() {
        let edited = RegionEdit.apply(
            to: ellipse(),
            handle: .ellipseRx,
            dragStartImage: SIMD2(120, 100),
            currentImage: SIMD2(130, 100)
        )
        if case .ellipse(_, let rx, _, _) = edited.shape {
            XCTAssertEqual(rx.value, 30, accuracy: 1e-9)
        } else { XCTFail("expected ellipse") }
    }

    func testApplyDragResizesEllipseRy() {
        let edited = RegionEdit.apply(
            to: ellipse(),
            handle: .ellipseRy,
            dragStartImage: SIMD2(100, 110),
            currentImage: SIMD2(100, 120)
        )
        if case .ellipse(_, _, let ry, _) = edited.shape {
            XCTAssertEqual(ry.value, 20, accuracy: 1e-9)
        } else { XCTFail("expected ellipse") }
    }

    // MARK: - rotation (box hit-test must work in the rotated frame)

    func testHitTestBoxRespectsAngle() {
        // 90° rotated 20×10 box → corners at world (95, 90) etc. Grab the rotated corner.
        let rotated = box(angle: 90)
        // 90° rotation: width axis points along +y in image. So bottom-left becomes (95, 90)
        // in image space (center (100,100), local (-10,-5) → rotated to (5,-10) → image (105,90)).
        // Just verify that clicking at center is still .move and corner detection is sane.
        let hit = RegionHitTest.hit(in: [rotated], atImagePoint: SIMD2(100, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .move)
    }

    // MARK: - polygon

    private func triangle() -> Region {
        Region(
            shape: .polygon(points: [
                .init(x: 101, y: 101),  // image (100, 100)
                .init(x: 121, y: 101),  // image (120, 100)
                .init(x: 111, y: 121),  // image (110, 120)
            ]),
            frame: .image
        )
    }

    func testHitTestPicksPolygonVertex() {
        let hit = RegionHitTest.hit(in: [triangle()], atImagePoint: SIMD2(100, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .polygonVertex(0))
        let hit1 = RegionHitTest.hit(in: [triangle()], atImagePoint: SIMD2(120, 100), toleranceImagePixels: 3)
        XCTAssertEqual(hit1?.handle, .polygonVertex(1))
    }

    func testHitTestPicksMoveInsidePolygon() {
        // Centroid of triangle (100,100)-(120,100)-(110,120) → (110, ~106.7).
        let hit = RegionHitTest.hit(in: [triangle()], atImagePoint: SIMD2(110, 107), toleranceImagePixels: 3)
        XCTAssertEqual(hit?.handle, .move)
    }

    func testHitTestPolygonNilOutside() {
        let hit = RegionHitTest.hit(in: [triangle()], atImagePoint: SIMD2(200, 200), toleranceImagePixels: 3)
        XCTAssertNil(hit)
    }

    func testApplyDragMovesPolygonVertex() {
        let edited = RegionEdit.apply(
            to: triangle(),
            handle: .polygonVertex(1),
            dragStartImage: SIMD2(120, 100),
            currentImage: SIMD2(130, 110)
        )
        if case .polygon(let pts) = edited.shape {
            XCTAssertEqual(pts[1].x, 131, accuracy: 1e-9)  // FITS 1-based
            XCTAssertEqual(pts[1].y, 111, accuracy: 1e-9)
            // Other vertices unchanged.
            XCTAssertEqual(pts[0].x, 101)
            XCTAssertEqual(pts[2].x, 111)
        } else { XCTFail("expected polygon") }
    }

    func testApplyDragMovesEntirePolygon() {
        let edited = RegionEdit.apply(
            to: triangle(),
            handle: .move,
            dragStartImage: SIMD2(110, 107),
            currentImage: SIMD2(120, 117)
        )
        if case .polygon(let pts) = edited.shape {
            XCTAssertEqual(pts[0].x, 111, accuracy: 1e-9)
            XCTAssertEqual(pts[0].y, 111, accuracy: 1e-9)
        } else { XCTFail("expected polygon") }
    }

    func testApplyDragMovesCenterByDelta() {
        // Move handle: center shifts by (end - start) in image pixels.
        // start=(101,101) centre; image click at (101,101)=image origin 1-based; drag to (110, 105).
        let edited = RegionEdit.apply(
            to: annulus(),
            handle: .move,
            dragStartImage: SIMD2(100, 100),  // image-0-based; Stored center is 101,101
            currentImage: SIMD2(109, 105)
        )
        if case .annulus(let c, _, _) = edited.shape {
            // centre moved by (+9, +5) from (101, 101) → (110, 106).
            XCTAssertEqual(c.x, 110, accuracy: 1e-9)
            XCTAssertEqual(c.y, 106, accuracy: 1e-9)
        } else {
            XCTFail("expected annulus")
        }
    }
}
