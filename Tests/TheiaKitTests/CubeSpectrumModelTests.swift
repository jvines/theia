import XCTest
@testable import TheiaKit

final class CubeSpectrumModelTests: XCTestCase {
    func testPlaneAxisAndAutoFitDefaultsToCurrentPlane() {
        let model = CubeSpectrumModel(values: [1, 2, 5, 2, 1], currentPlane: 1,
                                      label: "pixel", xValues: nil, xLabel: "plane")
        XCTAssertEqual(model.xs, [0, 1, 2, 3, 4])
        XCTAssertEqual(model.plotHighlight, 1)
        var mutable = model
        mutable.autoFit()
        XCTAssertEqual(mutable.fitCenterText, "1")
        XCTAssertEqual(mutable.fitHalfWidthText, "1")
    }

    func testDescendingSpectralAxisUsesAbsoluteSpanAndBrightestChannel() {
        var model = CubeSpectrumModel(values: [1, 3, 10, 2, 1], currentPlane: 20,
                                      label: "region", xValues: [20, 15, 10, 5, 0],
                                      xLabel: "wavelength")
        XCTAssertNil(model.plotHighlight)
        model.autoFit()
        XCTAssertEqual(model.fitCenterText, "10")
        XCTAssertEqual(model.fitHalfWidthText, "2")
        model.fitHalfWidthText = "invalid"
        model.runFit()
        XCTAssertEqual(model.fitHalfWidthText, "invalid")
    }
}
