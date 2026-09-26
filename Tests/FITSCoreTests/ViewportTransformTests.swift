import XCTest
#if canImport(simd)
import simd
#endif
@testable import FITSCore

final class ViewportTransformTests: XCTestCase {
    func testFitCentersImageInLargerSquareView() {
        // 100x100 image in 200x200 view: scale=2, centered → translation=(0,0)
        let t = ViewportTransform.fit(imageSize: SIMD2(100, 100), viewSize: SIMD2(200, 200))
        XCTAssertEqual(t.scale, 2.0, accuracy: 1e-12)
        XCTAssertEqual(t.translation.x, 0, accuracy: 1e-12)
        XCTAssertEqual(t.translation.y, 0, accuracy: 1e-12)
    }

    func testFitChoosesMinimumScaleAndCentersOnFreeAxis() {
        // 100x50 image in 200x200 view: scaleX=2, scaleY=4 → scale=2; image renders 200x100 centered → translation=(0, 50)
        let t = ViewportTransform.fit(imageSize: SIMD2(100, 50), viewSize: SIMD2(200, 200))
        XCTAssertEqual(t.scale, 2.0, accuracy: 1e-12)
        XCTAssertEqual(t.translation.x, 0, accuracy: 1e-12)
        XCTAssertEqual(t.translation.y, 50, accuracy: 1e-12)
    }

    func testZoomAroundAnchorKeepsAnchorFixed() {
        var t = ViewportTransform(scale: 1.0, translation: SIMD2(0, 0))
        let anchor = SIMD2(100.0, 100.0)
        let imagePointBefore = (anchor - t.translation) / t.scale
        t.zoom(by: 2.5, around: anchor)
        let imagePointAfter = (anchor - t.translation) / t.scale
        XCTAssertEqual(imagePointBefore.x, imagePointAfter.x, accuracy: 1e-12)
        XCTAssertEqual(imagePointBefore.y, imagePointAfter.y, accuracy: 1e-12)
        XCTAssertEqual(t.scale, 2.5, accuracy: 1e-12)
    }

    func testInverseRoundTripsAForwardMappedPoint() {
        let t = ViewportTransform(scale: 2.0, translation: SIMD2(10, 20))
        // Forward: view = scale * image + translation. image = (50, 50) → view = (110, 120).
        let view = SIMD2(110.0, 120.0)
        let recovered = t.inverse(view)
        XCTAssertEqual(recovered.x, 50, accuracy: 1e-12)
        XCTAssertEqual(recovered.y, 50, accuracy: 1e-12)
    }

    func testPanAddsToTranslation() {
        var t = ViewportTransform(scale: 1.0, translation: SIMD2(10, 20))
        t.pan(by: SIMD2(5, -3))
        XCTAssertEqual(t.translation.x, 15)
        XCTAssertEqual(t.translation.y, 17)
    }
}
