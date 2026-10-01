import XCTest
#if canImport(simd)
import simd
#endif
@testable import FITSCore

final class ColorMapTests: XCTestCase {
    func testGrayLUTHasBlackToWhite() {
        let lut = ColorMap.gray.lut()
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut[0].x, 0, accuracy: 1e-6)
        XCTAssertEqual(lut[0].y, 0, accuracy: 1e-6)
        XCTAssertEqual(lut[0].z, 0, accuracy: 1e-6)
        XCTAssertEqual(lut[255].x, 1, accuracy: 1e-6)
        XCTAssertEqual(lut[255].y, 1, accuracy: 1e-6)
        XCTAssertEqual(lut[255].z, 1, accuracy: 1e-6)
    }

    func testInvertedGrayLUTGoesWhiteToBlack() {
        let lut = ColorMap.invertedGray.lut()
        XCTAssertEqual(lut[0].x, 1, accuracy: 1e-6)
        XCTAssertEqual(lut[255].x, 0, accuracy: 1e-6)
    }

    func testViridisStartsDarkPurpleAndEndsYellow() {
        let lut = ColorMap.viridis.lut()
        // dark purple at start: R low-ish, G near zero, B mid
        XCTAssertLessThan(lut[0].x, 0.4)
        XCTAssertLessThan(lut[0].y, 0.1)
        XCTAssertGreaterThan(lut[0].z, 0.2)
        // yellow at end: R high, G high, B low
        XCTAssertGreaterThan(lut[255].x, 0.85)
        XCTAssertGreaterThan(lut[255].y, 0.75)
        XCTAssertLessThan(lut[255].z, 0.25)
    }

    func testAllLUTsAre256EntriesAndChannelsBetween0And1() {
        for map in ColorMap.allCases {
            let lut = map.lut()
            XCTAssertEqual(lut.count, 256, "\(map) LUT length")
            for (i, c) in lut.enumerated() {
                XCTAssertGreaterThanOrEqual(c.x, 0, "\(map)[\(i)].r")
                XCTAssertLessThanOrEqual(c.x, 1, "\(map)[\(i)].r")
                XCTAssertGreaterThanOrEqual(c.y, 0, "\(map)[\(i)].g")
                XCTAssertLessThanOrEqual(c.y, 1, "\(map)[\(i)].g")
                XCTAssertGreaterThanOrEqual(c.z, 0, "\(map)[\(i)].b")
                XCTAssertLessThanOrEqual(c.z, 1, "\(map)[\(i)].b")
            }
        }
    }

    // MARK: - DS9 maps

    private func assertColor(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4, "\(message) red", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4, "\(message) green", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-4, "\(message) blue", file: file, line: line)
    }

    func testDS9MapsUseDS9NamesAndMenuOrder() {
        XCTAssertEqual(ColorMap.allCases.map(\.rawValue), [
            "gray", "invertedGray", "viridis", "magma", "plasma",
            "red", "green", "blue", "a", "b", "bb", "he", "i8", "aips0", "sls", "hsv",
            "heat", "cool", "rainbow", "standard", "staircase", "color",
        ])
        XCTAssertEqual(ColorMap.heat.label, "Heat")
        XCTAssertEqual(ColorMap.aips0.label, "AIPS0")
        XCTAssertEqual(ColorMap.bb.label, "BB")
        XCTAssertEqual(ColorMap.a.label, "A")
    }

    func testDS9PiecewiseMapsInterpolateBetweenTheirVertices() {
        // heat: red (0,0)-(0.34,1); blue (0.65,0)-(0.98,1).
        assertColor(ColorMap.heat.sample(0.17), SIMD3(0.5, 0.17, 0), "heat 0.17")
        assertColor(ColorMap.heat.sample(0.815), SIMD3(1, 0.815, 0.5), "heat 0.815")
        // cool: red (0.29,0)-(0.76,0.1); green (0.22,0)-(0.96,1); blue (0,0)-(0.53,1).
        assertColor(ColorMap.cool.sample(0.59), SIMD3(0.1 * 0.3 / 0.47, 0.37 / 0.74, 1), "cool 0.59")
        assertColor(ColorMap.rainbow.sample(0), SIMD3(1, 0, 1), "rainbow start")
        assertColor(ColorMap.rainbow.sample(1), SIMD3(1, 0, 0), "rainbow end")
        assertColor(ColorMap.red.sample(0.25), SIMD3(0.25, 0, 0), "red")
        assertColor(ColorMap.he.sample(0.0075), SIMD3(0.25, 0, 0.0625), "he")
        // standard repeats positions: a step, not a ramp, at 0.333 and 0.666.
        assertColor(ColorMap.standard.sample(0.3329), SIMD3(0.3329 * 0.3 / 0.333, 0.3329 * 0.3 / 0.333,
                                                            0.3329 / 0.333), "standard below")
        assertColor(ColorMap.standard.sample(0.333), SIMD3(0, 0.3, 0), "standard at step")
    }

    func testDS9TablesAreEqualWidthBands() {
        assertColor(ColorMap.i8.sample(0.12), SIMD3(0, 0, 0), "i8 first band")
        assertColor(ColorMap.i8.sample(0.13), SIMD3(0, 1, 0), "i8 second band")
        assertColor(ColorMap.i8.sample(1), SIMD3(1, 1, 1), "i8 last band")
        assertColor(ColorMap.aips0.sample(0), SIMD3(0.196, 0.196, 0.196), "aips0 start")
        assertColor(ColorMap.aips0.sample(1), SIMD3(1, 0, 0), "aips0 end")
        assertColor(ColorMap.staircase.sample(4.5 / 15), SIMD3(0.3, 0.3, 1), "staircase blue top")
        assertColor(ColorMap.staircase.sample(1), SIMD3(1, 0.3, 0.3), "staircase red top")
        assertColor(ColorMap.color.sample(6.5 / 16), SIMD3(0, 0.18431, 0.93725), "color band 6")
        XCTAssertEqual(DS9ColorMaps.sls.count, 200)
        assertColor(ColorMap.sls.sample(12.5 / 200), SIMD3(0.5213, 0, 0.6346), "sls entry 12")
        assertColor(ColorMap.sls.sample(1), SIMD3(1, 1, 1), "sls end")
        XCTAssertEqual(DS9ColorMaps.hsv.count, 200)
        assertColor(ColorMap.hsv.sample(0), SIMD3(0, 0, 0), "hsv start")
        assertColor(ColorMap.hsv.sample(1), SIMD3(1, 1, 1), "hsv end")
    }

    func testOnlySteppedMapsReportDiscontinuities() {
        XCTAssertEqual(ColorMap.allCases.filter(\.hasDiscontinuities),
                       [.i8, .aips0, .sls, .hsv, .standard, .staircase, .color])
    }
}
