import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class ImageViewStateTests: XCTestCase {
    func testIndependentCanvasOwnsDisplayAndVisualSettings() async throws {
        await MainActor.run {
            let image = FITSImage.fromFloat32(pixels: [2, 4], width: 2, height: 1)
            let view = ImageViewState(image: image, stretch: .asinh, colorMap: .viridis)
            XCTAssertEqual(view.image?.physicalValue(x: 1, y: 0), 4)
            XCTAssertEqual(view.imageRevision, 0)
            XCTAssertEqual(view.stretch, .asinh)
            XCTAssertEqual(view.colorMap, .viridis)
            XCTAssertEqual(view.vmin, 2)
            XCTAssertEqual(view.vmax, 4)

            view.transform = ViewTransform(scale: 2, centre: SIMD2(0.5, 0))
            view.viewSizePoints = CGSize(width: 320, height: 200)
            view.backingScale = 2
            view.stretchParameter = 3
            XCTAssertEqual(view.transform.scale, 2)
            XCTAssertEqual(view.viewSizePoints.width, 320)
            XCTAssertEqual(view.backingScale, 2)
            XCTAssertEqual(view.stretchParameter, 3)
        }
    }

    func testResizeRefitsAFittedViewButKeepsAUserZoomOrPan() async throws {
        await MainActor.run {
            let image = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 8), width: 4, height: 2)
            let view = ImageViewState(image: image)
            func fit(_ width: Double, _ height: Double) -> ViewTransform {
                ViewTransform.fit(imageSize: SIMD2(4, 2), viewSize: SIMD2(width, height))
            }
            view.resize(to: CGSize(width: 400, height: 300), backingScale: 2)
            XCTAssertEqual(view.viewSizePoints, CGSize(width: 400, height: 300))
            XCTAssertEqual(view.backingScale, 2)
            XCTAssertNotEqual(view.transform, fit(400, 300), "only a fit is kept fitted")

            XCTAssertTrue(view.fitDisplayedImage())
            view.resize(to: CGSize(width: 120, height: 300), backingScale: 2)
            XCTAssertEqual(view.transform, fit(120, 300))
            view.resize(to: CGSize(width: 800, height: 900), backingScale: 1)
            XCTAssertEqual(view.transform, fit(800, 900))

            XCTAssertTrue(view.zoom(by: 2, aroundImagePoint: SIMD2(0, 0)))
            let zoomed = view.transform
            view.resize(to: CGSize(width: 300, height: 300), backingScale: 1)
            XCTAssertEqual(view.transform, zoomed)

            XCTAssertTrue(view.fitDisplayedImage())
            XCTAssertTrue(view.pan(by: SIMD2(10, 0)))
            let panned = view.transform
            view.resize(to: CGSize(width: 200, height: 100), backingScale: 1)
            XCTAssertEqual(view.transform, panned)
        }
    }
}
