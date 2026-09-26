import XCTest
import FITSCore
@testable import FITSRender

final class MPEGExportFrameTests: XCTestCase {
    func testFrameUsesNativeRasterWithPowerParameterAndFITSOrientation() {
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2, 3], width: 2, height: 2)
        let bytes = MPEGExport.renderFrameBytes(
            image: image, stretch: .power, vmin: 0, vmax: 3,
            colorMap: .invertedGray, parameter: 2
        )
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0, 255])
        XCTAssertEqual(Array(bytes[8..<12]), [255, 255, 255, 255])
        XCTAssertLessThanOrEqual(abs(Int(bytes[0]) - 142), 1)
    }
}
