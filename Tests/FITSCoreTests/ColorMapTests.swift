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

    // MARK: - Matplotlib maps

    private func assertColor(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4, "\(message) red", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4, "\(message) green", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-4, "\(message) blue", file: file, line: line)
    }

    func testMapsUseMatplotlibNames() {
        XCTAssertEqual(ColorMap.allCases.map(\.rawValue), [
            "gray", "invertedGray", "viridis", "magma", "plasma", "inferno", "cividis",
            "bone", "cool", "hot", "afmhot", "gist_heat", "copper", "cubehelix", "rainbow", "hsv",
        ])
        XCTAssertEqual(ColorMap.gistHeat.label, "Gist Heat")
        XCTAssertEqual(ColorMap.hsv.label, "HSV")
    }

    func testSegmentMapsInterpolateMatplotlibsVertices() {
        // hot: red (0, 0.0416)-(0.365079, 1); green (0.365079, 0)-(0.746032, 1).
        assertColor(ColorMap.hot.sample(0), SIMD3(0.0416, 0, 0), "hot start")
        assertColor(ColorMap.hot.sample(0.365079), SIMD3(1, 0, 0), "hot red knee")
        assertColor(ColorMap.hot.sample(0.746032), SIMD3(1, 1, 0), "hot green knee")
        assertColor(ColorMap.hot.sample(1), SIMD3(1, 1, 1), "hot end")
        assertColor(ColorMap.cool.sample(0.25), SIMD3(0.25, 0.75, 1), "cool")
        assertColor(ColorMap.bone.sample(0.365079),
                    SIMD3(0.365079 * 0.652778 / 0.746032, 0.319444, 0.444444), "bone")
        assertColor(ColorMap.copper.sample(0.5), SIMD3(0.5 / 0.809524, 0.3906, 0.24875), "copper")
        assertColor(ColorMap.hsv.sample(0), SIMD3(1, 0, 0), "hsv start")
        assertColor(ColorMap.hsv.sample(0.333333), SIMD3(0.03125, 1, 0), "hsv green")
        assertColor(ColorMap.hsv.sample(1), SIMD3(1, 0, 0.09375), "hsv end")
    }

    func testFunctionMapsEvaluateMatplotlibsFormulasClipped() {
        // afmhot: 2x, 2x - 0.5, 2x - 1.
        assertColor(ColorMap.afmhot.sample(0.25), SIMD3(0.5, 0, 0), "afmhot 0.25")
        assertColor(ColorMap.afmhot.sample(0.75), SIMD3(1, 1, 0.5), "afmhot 0.75")
        // gist_heat: 1.5x, 2x - 1, 4x - 3.
        assertColor(ColorMap.gistHeat.sample(0.875), SIMD3(1, 0.75, 0.5), "gist_heat 0.875")
        // rainbow: |2x - 0.5|, sin(πx), cos(πx/2).
        assertColor(ColorMap.rainbow.sample(0), SIMD3(0.5, 0, 1), "rainbow start")
        assertColor(ColorMap.rainbow.sample(0.5), SIMD3(0.5, 1, 0.7071068), "rainbow middle")
        // cubehelix at 0.5, worked by hand from Green's formula.
        assertColor(ColorMap.cubehelix.sample(0), SIMD3(0, 0, 0), "cubehelix start")
        assertColor(ColorMap.cubehelix.sample(0.5), SIMD3(0.627511, 0.474984, 0.286422), "cubehelix middle")
        assertColor(ColorMap.cubehelix.sample(1), SIMD3(1, 1, 1), "cubehelix end")
    }

    func testListedMapsInterpolateMatplotlibsTables() {
        XCTAssertEqual(MatplotlibColorMaps.inferno.count, 256)
        XCTAssertEqual(MatplotlibColorMaps.cividis.count, 256)
        assertColor(ColorMap.inferno.sample(0), SIMD3(0.001462, 0.000466, 0.013866), "inferno start")
        assertColor(ColorMap.inferno.sample(1), SIMD3(0.988362, 0.998364, 0.644924), "inferno end")
        assertColor(ColorMap.inferno.sample(0.5 / 255), SIMD3((0.001462 + 0.002267) / 2,
                                                             (0.000466 + 0.001270) / 2,
                                                             (0.013866 + 0.018570) / 2), "inferno first step")
        assertColor(ColorMap.cividis.sample(0), SIMD3(0, 0.135112, 0.304751), "cividis start")
        assertColor(ColorMap.cividis.sample(1), SIMD3(0.995737, 0.909344, 0.217772), "cividis end")
    }
}
