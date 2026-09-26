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
}
