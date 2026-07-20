import XCTest
import Foundation
@testable import FITSCore

/// Native-frame inference from CTYPE / RADESYS / EQUINOX.
final class WCSFrameTests: XCTestCase {

    private func wcs(_ ctype1: String, _ ctype2: String, extra: [String] = []) throws -> WCS {
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "CTYPE1  = '\(ctype1.padding(toLength: 8, withPad: " ", startingAt: 0))'",
            "CTYPE2  = '\(ctype2.padding(toLength: 8, withPad: " ", startingAt: 0))'",
            "CRPIX1  =                  1.0",
            "CRPIX2  =                  1.0",
            "CRVAL1  =                 10.0",
            "CRVAL2  =                 20.0",
            "CD1_1   =               -0.001",
            "CD1_2   =                  0.0",
            "CD2_1   =                  0.0",
            "CD2_2   =                0.001",
        ] + extra
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        s += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        let block = 2880
        if s.count % block != 0 { s += String(repeating: " ", count: block - s.count % block) }
        let (header, _) = try XCTUnwrap(try FITSHeader.parse(in: Data(s.utf8), at: 0))
        return try XCTUnwrap(WCS(header: header))
    }

    func testEquatorialDefaultsToICRS() throws {
        XCTAssertEqual(try wcs("RA---TAN", "DEC--TAN").nativeFrame, .icrs)
    }

    func testRADESYSFK5() throws {
        XCTAssertEqual(try wcs("RA---TAN", "DEC--TAN", extra: ["RADESYS = 'FK5'"]).nativeFrame, .fk5)
    }

    func testEquinox1950IsFK4() throws {
        XCTAssertEqual(try wcs("RA---TAN", "DEC--TAN", extra: ["EQUINOX =               1950.0"]).nativeFrame, .fk4)
    }

    func testGalacticCTYPE() throws {
        XCTAssertEqual(try wcs("GLON-TAN", "GLAT-TAN").nativeFrame, .galactic)
    }

    func testEclipticCTYPE() throws {
        XCTAssertEqual(try wcs("ELON-TAN", "ELAT-TAN").nativeFrame, .ecliptic)
    }
}
