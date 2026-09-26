import XCTest
import FITSCore
@testable import TheiaKit

final class ViewMappingTests: XCTestCase {
    func testImageAndViewRoundTripAtCommonBackingScales() {
        let transform = ViewTransform(scale: 2, centre: SIMD2(9.0, 4.0))
        for backingScale in [1.0, 1.5, 2.0] {
            let mapping = ViewMapping(
                transform: transform,
                viewSize: SIMD2(200.0, 100.0),
                backingScale: backingScale
            )
            let image = SIMD2(12.25, 2.5)
            let view = mapping.imageToView(image)
            XCTAssertEqual(view.x, 106.5, accuracy: 1e-12)
            XCTAssertEqual(view.y, 53, accuracy: 1e-12)
            let recovered = mapping.viewToImage(view)
            XCTAssertEqual(recovered.x, image.x, accuracy: 1e-12)
            XCTAssertEqual(recovered.y, image.y, accuracy: 1e-12)
            let device = mapping.imageToDevice(image)
            XCTAssertEqual(device.x, view.x * backingScale, accuracy: 1e-12)
            XCTAssertEqual(device.y, view.y * backingScale, accuracy: 1e-12)
            let fromDevice = mapping.deviceToImage(device)
            XCTAssertEqual(fromDevice.x, image.x, accuracy: 1e-12)
            XCTAssertEqual(fromDevice.y, image.y, accuracy: 1e-12)
        }
    }

    func testPixelZeroIsCentredAndPixelEdgesAreHalfAPixelAway() {
        let mapping = ViewMapping(
            transform: ViewTransform.fit(
                imageSize: SIMD2(2.0, 2.0),
                viewSize: SIMD2(20.0, 20.0)
            ),
            viewSize: SIMD2(20.0, 20.0),
            backingScale: 1
        )
        let centre = mapping.imageToView(SIMD2(0.0, 0.0))
        XCTAssertEqual(centre.x, 5, accuracy: 1e-12)
        XCTAssertEqual(centre.y, 15, accuracy: 1e-12)
        let topLeftEdge = mapping.imageToView(SIMD2(-0.5, 1.5))
        XCTAssertEqual(topLeftEdge.x, 0, accuracy: 1e-12)
        XCTAssertEqual(topLeftEdge.y, 0, accuracy: 1e-12)
        XCTAssertEqual(mapping.nearestImagePixel(toView: centre), SIMD2(0, 0))
    }

    func testResizeKeepsZoomAndImageCentre() {
        let transform = ViewTransform(scale: 3, centre: SIMD2(40.0, 20.0))
        let before = ViewMapping(
            transform: transform, viewSize: SIMD2(120.0, 80.0), backingScale: 1
        )
        let after = ViewMapping(
            transform: transform, viewSize: SIMD2(200.0, 140.0), backingScale: 1
        )
        XCTAssertEqual(before.viewToImage(SIMD2(60.0, 40.0)), transform.centre)
        XCTAssertEqual(after.viewToImage(SIMD2(100.0, 70.0)), transform.centre)
        XCTAssertEqual(after.transform.scale, 3)
    }

    func testZoomAroundViewAnchorKeepsTheSameImagePoint() {
        var transform = ViewTransform(scale: 2, centre: SIMD2(40.0, 20.0))
        let anchor = SIMD2(75.0, 30.0)
        let before = ViewMapping(
            transform: transform, viewSize: SIMD2(120.0, 80.0), backingScale: 1
        )
        let imageAnchor = before.viewToImage(anchor)
        transform.zoom(by: 3, aroundImagePoint: imageAnchor)
        let after = ViewMapping(
            transform: transform, viewSize: SIMD2(120.0, 80.0), backingScale: 1
        )
        let recovered = after.viewToImage(anchor)
        XCTAssertEqual(recovered.x, imageAnchor.x, accuracy: 1e-12)
        XCTAssertEqual(recovered.y, imageAnchor.y, accuracy: 1e-12)
    }

    func testUnflippedViewConversionAndPixelTie() {
        let mapping = ViewMapping(
            transform: ViewTransform(scale: 10, centre: SIMD2(0.0, 0.0)),
            viewSize: SIMD2(100.0, 100.0), backingScale: 1
        )
        XCTAssertEqual(mapping.viewYUpToImage(SIMD2(50.0, 50.0)), SIMD2(0, 0))
        XCTAssertEqual(mapping.imageToViewYUp(SIMD2(0.0, 1.0)), SIMD2(50, 60))
        XCTAssertEqual(mapping.nearestImagePixel(toView: SIMD2(55.0, 50.0)), SIMD2(1, 0))
        XCTAssertEqual(mapping.nearestImagePixel(toView: SIMD2(45.0, 50.0)), SIMD2(0, 0))
    }

    func testDS9RegionCentreLandsOnImagePixelCentre() {
        let region = RegionDrawing.makeCircle(
            startImage: SIMD2(9.0, 9.0), endImage: SIMD2(11.0, 9.0)
        )
        guard case .circle(let point, _) = region.shape else {
            return XCTFail("Expected circle")
        }
        XCTAssertEqual(point, Region.Point(x: 10, y: 10))
        let mapping = ViewMapping(
            transform: ViewTransform(scale: 4, centre: SIMD2(9.0, 9.0)),
            viewSize: SIMD2(100.0, 100.0), backingScale: 1
        )
        XCTAssertEqual(mapping.imageToView(SIMD2(point.x - 1, point.y - 1)), SIMD2(50, 50))
    }
}
