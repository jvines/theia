import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class MeasurementTests: XCTestCase {
    func testSubpixelSkyDistanceUsesExactEndpoints() throws {
        let result = Measurements.between(from: SIMD2(0.25, 0.25),
                                          to: SIMD2(0.75, 0.25), wcs: try makeWCS())
        XCTAssertEqual(result.pixelDistance, 0.5)
        XCTAssertEqual(try XCTUnwrap(result.skyDistanceArcsec), 0.5, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(result.positionAngleDeg), 270, accuracy: 1e-3)
        XCTAssertEqual(result.lines[0], "Pixel distance: 0.50 px")
        XCTAssertEqual(result.lines[1], "Sky distance: 0.500″")
    }

    func testNoWCSStillReturnsPixelDistanceOnly() {
        let result = Measurements.between(from: SIMD2(1, 2), to: SIMD2(4, 6), wcs: nil)
        XCTAssertEqual(result.pixelDistance, 5)
        XCTAssertNil(result.skyDistanceArcsec)
        XCTAssertEqual(result.lines, ["Pixel distance: 5.00 px"])
    }

    private func makeWCS() throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  =                  1.0", "CRPIX2  =                  1.0",
            "CRVAL1  =                180.0", "CRVAL2  =                  0.0",
            "CDELT1  =        -0.0002777778", "CDELT2  =         0.0002777778", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try XCTUnwrap(WCS(header: FITSFile(data: Data(text.utf8)).hdus[0].header))
    }
}
