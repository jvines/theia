import XCTest
import FITSCore
@testable import TheiaKit

final class LineProfileModelTests: XCTestCase {
    func testSampleCountKeepsMinimumAndDoublesRoundedUpLength() {
        XCTAssertEqual(LineProfileModel.sampleCount(from: .init(0, 0), to: .init(2, 0)), 64)
        XCTAssertEqual(LineProfileModel.sampleCount(from: .init(0, 0), to: .init(32.1, 0)), 66)
    }

    func testModelSamplesDisplayedImageAndExposesPlotAxes() {
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2], width: 3, height: 1)
        let model = LineProfileModel(image: image, from: .init(0, 0), to: .init(2, 0))
        XCTAssertEqual(model.samples.count, 64)
        XCTAssertEqual(model.xValues.first, 0)
        XCTAssertEqual(model.xValues.last, 2)
        XCTAssertEqual(model.yValues.first, 0)
        XCTAssertEqual(model.yValues.last, 2)
    }
}
