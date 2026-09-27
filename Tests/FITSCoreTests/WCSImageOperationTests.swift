import Foundation
import XCTest
@testable import FITSCore

final class WCSImageOperationTests: XCTestCase {
    func testCropShiftsReferencePixelWithoutChangingSkyCoordinates() throws {
        let source = try makeWCS()
        let cropped = source.cropped(originX: 12, originY: 7)
        XCTAssertEqual(cropped.crpix.x, source.crpix.x - 12)
        XCTAssertEqual(cropped.crpix.y, source.crpix.y - 7)
        XCTAssertEqual(cropped.name, source.name)
        XCTAssertEqual(cropped.sipForward, source.sipForward)
        let old = try XCTUnwrap(source.pixelToSky(imageX: 16, imageY: 11))
        let new = try XCTUnwrap(cropped.pixelToSky(imageX: 4, imageY: 4))
        XCTAssertEqual(new.ra, old.ra, accuracy: 1e-9)
        XCTAssertEqual(new.dec, old.dec, accuracy: 1e-9)
    }

    func testBinMapsPixelCenterAndRescalesSIPCoefficients() throws {
        let source = try makeWCS()
        let binned = try XCTUnwrap(source.binned(by: 2))
        XCTAssertEqual(binned.crpix.x, (source.crpix.x - 0.5) / 2 + 0.5, accuracy: 1e-12)
        XCTAssertEqual(binned.cd11, source.cd11 * 2, accuracy: 1e-15)
        XCTAssertEqual(binned.sipForward?.a[2][0], 2e-4)
        XCTAssertEqual(binned.sipInverse?.a[2][0], -2e-4)
        let old = try XCTUnwrap(source.pixelToSky(imageX: 20.5, imageY: 12.5))
        let new = try XCTUnwrap(binned.pixelToSky(imageX: 10, imageY: 6))
        XCTAssertEqual(new.ra, old.ra, accuracy: 1e-9)
        XCTAssertEqual(new.dec, old.dec, accuracy: 1e-9)
    }

    func testCropThenBinKeepsSkyCoordinatesForChainedOperations() throws {
        let source = try makeWCS()
        let chained = try XCTUnwrap(source.cropped(originX: 12, originY: 7).binned(by: 3))
        let old = try XCTUnwrap(source.pixelToSky(imageX: 12 + 3 * 4 + 1,
                                                  imageY: 7 + 3 * 5 + 1))
        let new = try XCTUnwrap(chained.pixelToSky(imageX: 4, imageY: 5))
        XCTAssertEqual(new.ra, old.ra, accuracy: 1e-9)
        XCTAssertEqual(new.dec, old.dec, accuracy: 1e-9)
        XCTAssertNil(source.binned(by: 0))
    }

    private func makeWCS() throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN-SIP'", "CTYPE2  = 'DEC--TAN-SIP'",
            "CRPIX1  =                 50.0", "CRPIX2  =                 50.0",
            "CRVAL1  =                180.0", "CRVAL2  =                  0.0",
            "CD1_1   =        -0.0002777778", "CD1_2   =                  0.0",
            "CD2_1   =                  0.0", "CD2_2   =         0.0002777778",
            "WCSNAME = 'test sky'", "A_ORDER =                    2", "B_ORDER =                    2",
            "A_2_0   =               0.0001", "B_0_2   =               0.0002",
            "AP_ORDER=                    2", "BP_ORDER=                    2",
            "AP_2_0  =              -0.0001", "BP_0_2  =              -0.0002", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try XCTUnwrap(WCS(header: FITSFile(data: Data(text.utf8)).hdus[0].header))
    }
}
