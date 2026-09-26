import XCTest
@testable import FITSCore

final class ViewTransformTests: XCTestCase {
    func testFitCentresPixelCentresInTheView() {
        let transform = ViewTransform.fit(
            imageSize: SIMD2(100.0, 50.0),
            viewSize: SIMD2(200.0, 200.0)
        )
        XCTAssertEqual(transform.scale, 2)
        XCTAssertEqual(transform.centre.x, 49.5)
        XCTAssertEqual(transform.centre.y, 24.5)
    }

    func testZoomKeepsAnchorImagePointFixed() {
        var transform = ViewTransform(scale: 2, centre: SIMD2(40.0, 30.0))
        let anchor = SIMD2(70.0, 45.0)
        transform.zoom(by: 4, aroundImagePoint: anchor)
        XCTAssertEqual(transform.scale, 8)
        XCTAssertEqual(transform.centre.x, 62.5, accuracy: 1e-12)
        XCTAssertEqual(transform.centre.y, 41.25, accuracy: 1e-12)
    }

    func testPanUsesViewPointsAndFlipsImageY() {
        var transform = ViewTransform(scale: 2, centre: SIMD2(40.0, 30.0))
        transform.pan(by: SIMD2(12.0, -6.0))
        XCTAssertEqual(transform.centre.x, 34)
        XCTAssertEqual(transform.centre.y, 27)
    }
}
