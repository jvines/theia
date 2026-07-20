import XCTest
import simd
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
}
