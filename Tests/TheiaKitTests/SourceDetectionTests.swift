import XCTest
import FITSCore
@testable import TheiaKit

final class SourceDetectionTests: XCTestCase {
    func testDetectionBuildsTaggedGaussianRegionAndSummary() throws {
        let width = 21, height = 21
        let pixels = (0..<(width * height)).map { index -> Float in
            let x = Double(index % width) - 10
            let y = Double(index / width) - 10
            return Float(1 + 100 * exp(-(x * x + y * y) / 4.5))
        }
        let image = FITSImage.fromFloat32(pixels: pixels, width: width, height: height)
        let result = try SourceDetectionResult.analyze(image: image, threshold: 5)
        XCTAssertEqual(result.regions.count, 1)
        XCTAssertEqual(result.fittedCount, 1)
        XCTAssertEqual(result.regions[0].attributes["color"], "yellow")
        XCTAssertEqual(result.regions[0].attributes["tag"], "sources")
        XCTAssertTrue(result.noticeTitle?.contains("Detected 1 sources") ?? false)
        XCTAssertTrue(result.noticeMessage?.contains("FWHM (px)") ?? false)
    }
}
