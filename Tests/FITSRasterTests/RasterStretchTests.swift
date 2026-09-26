import XCTest
import FITSCore
@testable import FITSRaster

final class RasterStretchTests: XCTestCase {
    func testNonfiniteValuesAndDegenerateLevels() {
        let levels = RasterLevels(vmin: .nan, vmax: .infinity)
        XCTAssertEqual(levels.vmin, 0)
        XCTAssertEqual(levels.vmax, 1)
        XCTAssertTrue(RasterStretch.apply(.nan, stretch: .linear, levels: levels).isNaN)
        XCTAssertEqual(RasterStretch.apply(-.infinity, stretch: .linear, levels: levels), 0)
        XCTAssertEqual(RasterStretch.apply(.infinity, stretch: .linear, levels: levels), 1)
        XCTAssertEqual(RasterStretch.apply(-10, stretch: .linear, levels: levels), 0)
        XCTAssertEqual(RasterStretch.apply(10, stretch: .linear, levels: levels), 1)
        XCTAssertEqual(RasterLevels(vmin: 5, vmax: 5), levels)
        XCTAssertEqual(RasterLevels(vmin: 10, vmax: -2), levels)
    }

    func testFloatStretchesTrackDoubleReference() {
        let levels = RasterLevels(vmin: -3, vmax: 7)
        for stretch in ImageStretch.allCases where stretch != .histogramEq {
            for i in 0...1000 {
                let value = Float(i) / 100 - 4
                let actual = RasterStretch.apply(value, stretch: stretch, levels: levels, parameter: 0.3)
                let expected = stretch.apply(Double(value), vmin: -3, vmax: 7, parameter: 0.3)
                XCTAssertEqual(Double(actual), expected, accuracy: 1.0 / 255.0)
            }
        }
    }

    func testCDFUsesSelectedLevelsAndExcludesOutsideValues() {
        let levels = RasterLevels(vmin: 0, vmax: 3)
        let cdf = RasterCDF.make(sortedFiniteSample: [-100, 0, 1, 2, 3, 100], levels: levels)
        XCTAssertEqual(cdf.count, 256)
        XCTAssertEqual(cdf[0], 0.25)
        XCTAssertEqual(cdf[85], 0.5)
        XCTAssertEqual(cdf[170], 0.75)
        XCTAssertEqual(cdf[255], 1)
        XCTAssertEqual(RasterStretch.apply(1, stretch: .histogramEq, levels: levels, cdf: cdf), cdf[85])
        XCTAssertEqual(RasterCDF.make(sortedFiniteSample: [], levels: levels), [Float](repeating: 0, count: 256))
    }
}
