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

    func testDenseFloatRasterColorAgainstDoubleReference() {
        let levels = RasterLevels(vmin: 0, vmax: 1)
        let values = (0...4096).map { Float($0) / 4096 } +
            (0...256).map { Float(pow(10.0, -12.0 + Double($0) * 12.0 / 256.0)) }
        let sample: [Float] = [0, 0.1, 0.1, 0.4, 0.9, 1]
        let cdf = RasterCDF.make(sortedFiniteSample: sample, levels: levels)
        for map in ColorMap.allCases {
            let table = ColorTable(map: map)
            for stretch in ImageStretch.allCases {
                let parameters: [Float] = stretch == .power ? [0.1, 0.3, 2, 8] : [2]
                for parameter in parameters {
                    for value in values {
                        let n = RasterStretch.apply(
                            value, stretch: stretch, levels: levels,
                            parameter: parameter, cdf: cdf
                        )
                        let referenceN = stretch.apply(
                            Double(value), vmin: 0, vmax: 1,
                            parameter: Double(parameter), cdf: cdf.map(Double.init)
                        )
                        let actual = table.color(for: n)
                        let expected = RGBA8(map.sample(Float(referenceN)))
                        let caseLabel = "\(map) \(stretch) p=\(parameter) value=\(value) n=\(n) expectedN=\(referenceN) table=\(table.entries.count) actual=\(actual) expected=\(expected)"
                        XCTAssertLessThanOrEqual(abs(Int(actual.r) - Int(expected.r)), 1, caseLabel)
                        XCTAssertLessThanOrEqual(abs(Int(actual.g) - Int(expected.g)), 1, caseLabel)
                        XCTAssertLessThanOrEqual(abs(Int(actual.b) - Int(expected.b)), 1, caseLabel)
                    }
                }
            }
        }
    }

    func testLevelCDFMatchesFullImageHistogramOnFixture() {
        let values = (0..<4096).map { Float(($0 * 37) % 101) }
        let levels = RasterLevels(vmin: 10, vmax: 90)
        let sampled = RasterCDF.make(sortedFiniteSample: values.sorted(), levels: levels)
        let full = PixelStatistics.histogram(
            values.map(Double.init), bins: 256, range: 10...90
        ).cdf()
        for i in 0..<256 {
            XCTAssertEqual(Double(sampled[i]), full[i], accuracy: 1.0 / 255.0)
        }
    }
}
