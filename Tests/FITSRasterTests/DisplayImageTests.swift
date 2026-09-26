import XCTest
import FITSCore
@testable import FITSRaster

final class DisplayImageTests: XCTestCase {
    func testStoresPhysicalFloatPixelsAndCallerRevision() {
        let image = FITSImage.fromFloat32(
            pixels: [1, .nan, .infinity, -3], width: 2, height: 2
        )
        let display = DisplayImage(image: image, revision: 7)

        XCTAssertEqual(display.width, 2)
        XCTAssertEqual(display.height, 2)
        XCTAssertEqual(display.revision, 7)
        XCTAssertEqual(display.pixels[0], 1)
        XCTAssertTrue(display.pixels[1].isNaN)
        XCTAssertEqual(display.pixels[2], .infinity)
        XCTAssertEqual(display.pixels[3], -3)
        XCTAssertEqual(display.sortedFiniteSample, [-3, 1])
    }

    func testLargeFiniteSampleHasFixedSizeAndDeterministicEndpoints() {
        let count = (1 << 20) + 2
        let image = FITSImage.fromFloat32(
            pixels: (0..<count).map(Float.init), width: count, height: 1
        )
        let display = DisplayImage(image: image, revision: 1)
        XCTAssertEqual(display.sortedFiniteSample.count, 1 << 20)
        XCTAssertEqual(display.sortedFiniteSample.first, 0)
        XCTAssertEqual(display.sortedFiniteSample.last, Float(count - 1))
    }
}
