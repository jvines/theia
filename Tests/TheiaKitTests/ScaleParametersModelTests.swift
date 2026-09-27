import XCTest
@testable import TheiaKit

final class ScaleParametersModelTests: XCTestCase {
    func testHistogramAndCoordinateMapping() throws {
        let model = ScaleParametersModel(values: [0, 1, 2, 3, .nan], vmin: 1, vmax: 2)
        XCTAssertEqual(model.dataMin, 0)
        XCTAssertEqual(model.dataMax, 3)
        XCTAssertEqual(model.histogram?.counts.count, 256)
        XCTAssertEqual(model.histogram?.counts.reduce(0, +), 4)
        XCTAssertEqual(model.barHeights.count, 256)
        XCTAssertEqual(try XCTUnwrap(model.barHeights.max()), 1, accuracy: 1e-12)
        XCTAssertEqual(model.xForValue(1.5, width: 100), 50, accuracy: 1e-12)
        XCTAssertEqual(model.valueForX(-10, width: 100), 0)
        XCTAssertEqual(model.valueForX(120, width: 100), 3)
        XCTAssertEqual(model.stepSize, 3.0 / 200)
    }

    func testHandleClampAndLevelControls() {
        var model = ScaleParametersModel(values: [1, 2], vmin: 1, vmax: 2)
        XCTAssertLessThan(model.movedVmin(current: 1, vmax: 2, deltaX: 1000, width: 100), 2)
        XCTAssertGreaterThan(model.movedVmax(current: 2, vmin: 1, deltaX: -1000, width: 100), 1)
        let wide = ScaleParametersModel(values: [0, 1000], vmin: 0, vmax: 1000)
        XCTAssertLessThan(Float(wide.movedVmin(current: 0, vmax: 1000,
                                                deltaX: 100, width: 100)), 1000)
        XCTAssertGreaterThan(Float(wide.movedVmax(current: 1000, vmin: 1000,
                                                   deltaX: -100, width: 100)), 1000)
        model.vminText = "1.25"
        model.vmaxText = "bad"
        XCTAssertEqual(model.parsedVmin, 1.25)
        XCTAssertNil(model.parsedVmax)
        model.refreshLevels(vmin: 1, vmax: 2)
        XCTAssertEqual(model.vminText, "1.0000")
        XCTAssertEqual(model.vmaxText, "2.0000")
        model.lowerPctText = "0.5"
        model.upperPctText = "99.5"
        XCTAssertEqual(model.percentilePreset, .percentile(lower: 0.5, upper: 99.5))
        XCTAssertEqual(ScaleParametersModel.presets, ScalePreset.toolbarPresets)
        XCTAssertEqual(model.clampedPowerExponent(20), 8)
        XCTAssertEqual(model.clampedPowerExponent(0), 0.1)
    }

    func testEmptyAndConstantImagesHaveNoHistogram() {
        let empty = ScaleParametersModel(values: [.nan, .infinity], vmin: 0, vmax: 1)
        XCTAssertNil(empty.histogram)
        XCTAssertEqual(empty.histogramPlaceholder, "No finite pixel values")
        XCTAssertEqual(empty.stepSize, 1)
        let constant = ScaleParametersModel(values: [4, 4], vmin: 4, vmax: 4)
        XCTAssertNil(constant.histogram)
        XCTAssertEqual(constant.histogramPlaceholder, "All finite pixels have the same value")
        XCTAssertEqual(constant.stepSize, 1e-9 / 200, accuracy: 1e-20)
    }

    func testExtremeFiniteRangesDoNotCrashHistogramBinning() {
        let wide = ScaleParametersModel(
            values: [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude],
            vmin: 0, vmax: 1
        )
        XCTAssertNil(wide.histogram)
        XCTAssertEqual(wide.histogramPlaceholder, "Data range cannot be binned")
        let tiny = Double.leastNonzeroMagnitude
        let narrow = ScaleParametersModel(values: [tiny, tiny * 2], vmin: 0, vmax: 1)
        XCTAssertNil(narrow.histogram)
        XCTAssertEqual(narrow.histogramPlaceholder, "Data range cannot be binned")
        let roundedWidth = ScaleParametersModel(values: [0, tiny * 257], vmin: 0, vmax: 1)
        XCTAssertEqual(roundedWidth.histogram?.counts.last, 1)
    }
}
