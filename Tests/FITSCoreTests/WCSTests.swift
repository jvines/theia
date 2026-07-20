import XCTest
@testable import FITSCore

final class WCSTests: XCTestCase {
    func testReturnsNilWhenWCSKeywordsMissing() throws {
        let header = try parseHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "END",
        ])
        XCTAssertNil(WCS(header: header))
    }

    func testTANIdentityAtReferencePixel() throws {
        let header = try parseHeader(tanHeader(
            crpix: (1, 1),
            crval: (0, 0),
            cd: (-1, 0, 0, 1)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 0, imageY: 0))
        XCTAssertEqual(sky.ra, 0, accuracy: 1e-9)
        XCTAssertEqual(sky.dec, 0, accuracy: 1e-9)
    }

    func testPixelOffsetMapsToCorrectRAShiftAtEquator() throws {
        // 1 arcsec/pixel, ref at (180°, 0°), CD1_1 = -1/3600.
        let header = try parseHeader(tanHeader(
            crpix: (1, 1),
            crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 100, imageY: 0))
        // 100 px right = 100 arcsec west (CD1_1 < 0); at equator cos δ = 1 so RA shift ≈ -100/3600 deg.
        XCTAssertEqual(sky.ra, 180 - 100.0 / 3600, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 0, accuracy: 1e-9)
    }

    func testPixelOffsetMapsToCorrectDecShift() throws {
        let header = try parseHeader(tanHeader(
            crpix: (1, 1),
            crval: (180, 30),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 0, imageY: 100))
        XCTAssertEqual(sky.dec, 30 + 100.0 / 3600, accuracy: 1e-6)
    }

    func testNegativeRAWrapsToPositive() throws {
        // ref at RA=0°: moving right (CD1_1 < 0) gives negative RA which should wrap.
        let header = try parseHeader(tanHeader(
            crpix: (1, 1),
            crval: (0, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 100, imageY: 0))
        // Should wrap to ~360° - 100/3600
        XCTAssertEqual(sky.ra, 360 - 100.0 / 3600, accuracy: 1e-6)
    }

    func testCDELTAndCROTAFallback() throws {
        // CDELT only (no CD matrix), no rotation.
        let header = try parseHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'         ",
            "CTYPE2  = 'DEC--TAN'         ",
            "CRPIX1  = \(format(1.0))",
            "CRPIX2  = \(format(1.0))",
            "CRVAL1  = \(format(180.0))",
            "CRVAL2  = \(format(0.0))",
            "CDELT1  = \(format(-1.0/3600))",
            "CDELT2  = \(format(1.0/3600))",
            "END",
        ])
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 100, imageY: 100))
        XCTAssertEqual(sky.ra, 180 - 100.0 / 3600, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 100.0 / 3600, accuracy: 1e-6)
    }

    func testSkyToPixelRoundTripsThroughPixelToSky() throws {
        let header = try parseHeader(tanHeader(
            crpix: (50, 50),
            crval: (180, 30),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        for (x, y) in [(0, 0), (49, 49), (100, 80), (10, 90)] {
            let sky = try XCTUnwrap(wcs.pixelToSky(imageX: x, imageY: y))
            let pix = try XCTUnwrap(wcs.skyToPixel(ra: sky.ra, dec: sky.dec))
            XCTAssertEqual(pix.x, Double(x), accuracy: 1e-6, "x mismatch at (\(x),\(y))")
            XCTAssertEqual(pix.y, Double(y), accuracy: 1e-6, "y mismatch at (\(x),\(y))")
        }
    }

    func testSkyToPixelAtReferenceValueReturnsReferencePixel() throws {
        let header = try parseHeader(tanHeader(
            crpix: (50, 50),
            crval: (180, 30),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let pix = try XCTUnwrap(wcs.skyToPixel(ra: 180, dec: 30))
        // CRPIX is 1-based; the 0-based image coord is CRPIX - 1.
        XCTAssertEqual(pix.x, 49, accuracy: 1e-9)
        XCTAssertEqual(pix.y, 49, accuracy: 1e-9)
    }

    func testSkyToPixelRoundTripsForSINProjection() throws {
        let header = try parseHeader(projectionHeader(
            ctype1: "RA---SIN", ctype2: "DEC--SIN",
            crpix: (1, 1), crval: (10, 5),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 100, imageY: 50))
        let pix = try XCTUnwrap(wcs.skyToPixel(ra: sky.ra, dec: sky.dec))
        XCTAssertEqual(pix.x, 100, accuracy: 1e-6)
        XCTAssertEqual(pix.y, 50, accuracy: 1e-6)
    }

    func testSINProjectionIdentityAtReferencePixel() throws {
        let header = try parseHeader(projectionHeader(
            ctype1: "RA---SIN", ctype2: "DEC--SIN",
            crpix: (1, 1), crval: (180, 0), cd: (-1.0/3600, 0, 0, 1.0/3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 0, imageY: 0))
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-9)
        XCTAssertEqual(sky.dec, 0, accuracy: 1e-9)
    }

    func testZEAProjectionIdentityAtReferencePixel() throws {
        let header = try parseHeader(projectionHeader(
            ctype1: "RA---ZEA", ctype2: "DEC--ZEA",
            crpix: (1, 1), crval: (45, 60), cd: (-1.0/3600, 0, 0, 1.0/3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let sky = try XCTUnwrap(wcs.pixelToSky(imageX: 0, imageY: 0))
        XCTAssertEqual(sky.ra, 45, accuracy: 1e-9)
        XCTAssertEqual(sky.dec, 60, accuracy: 1e-9)
    }

    func testSINAtSmallOffsetMatchesTANWithinArcsec() throws {
        // At 1 px = 1 arcsec the three zenithal projections agree to <<1 arcsec.
        let scale = 1.0 / 3600
        let crpix: (Double, Double) = (1, 1)
        let crval: (Double, Double) = (180, 0)
        let cd: (Double, Double, Double, Double) = (-scale, 0, 0, scale)
        let tan = try XCTUnwrap(WCS(header: parseHeader(tanHeader(crpix: crpix, crval: crval, cd: cd))))
        let sin = try XCTUnwrap(WCS(header: parseHeader(projectionHeader(
            ctype1: "RA---SIN", ctype2: "DEC--SIN", crpix: crpix, crval: crval, cd: cd
        ))))
        let tanSky = try XCTUnwrap(tan.pixelToSky(imageX: 100, imageY: 50))
        let sinSky = try XCTUnwrap(sin.pixelToSky(imageX: 100, imageY: 50))
        XCTAssertEqual(tanSky.ra, sinSky.ra, accuracy: 1.0 / 3600)
        XCTAssertEqual(tanSky.dec, sinSky.dec, accuracy: 1.0 / 3600)
    }

    func testSINAndTANDiffersAtLargeOffset() throws {
        // At 30° offset the SIN and TAN formulae give visibly different RA.
        let crpix: (Double, Double) = (1, 1)
        let crval: (Double, Double) = (0, 0)
        let cd: (Double, Double, Double, Double) = (-1.0, 0, 0, 1.0)
        let tan = try XCTUnwrap(WCS(header: parseHeader(tanHeader(crpix: crpix, crval: crval, cd: cd))))
        let sin = try XCTUnwrap(WCS(header: parseHeader(projectionHeader(
            ctype1: "RA---SIN", ctype2: "DEC--SIN", crpix: crpix, crval: crval, cd: cd
        ))))
        let tanSky = try XCTUnwrap(tan.pixelToSky(imageX: 30, imageY: 0))
        let sinSky = try XCTUnwrap(sin.pixelToSky(imageX: 30, imageY: 0))
        XCTAssertGreaterThan(abs(tanSky.ra - sinSky.ra), 1.0)  // differ by > 1°
    }

    func testSINBeyondUnitSphereReturnsNil() throws {
        // CD scaled so 1 pixel = 90° → rho = π/2 > 1 (SIN unit sphere boundary at 1).
        // Use 2 pixels and 60°/pix to land at xi = -120° = -2.09 rad > 1.
        let header = try parseHeader(projectionHeader(
            ctype1: "RA---SIN", ctype2: "DEC--SIN",
            crpix: (1, 1), crval: (0, 0), cd: (-60, 0, 0, 1)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        XCTAssertNil(wcs.pixelToSky(imageX: 2, imageY: 0))
    }

    func testSampleFITSWCSResolvesCentreAndOffsetCorrectly() throws {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sample.fits")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("sample.fits not present")
        }
        let data = try Data(contentsOf: path)
        let file = try FITSFile(data: data)
        let wcs = try XCTUnwrap(WCS(header: file.hdus[0].header))
        // generator: 200x200 image, CRPIX = (100, 100), CRVAL = (180°, 0°), 1 arcsec/pix.
        let centre = try XCTUnwrap(wcs.pixelToSky(imageX: 99, imageY: 99))
        XCTAssertEqual(centre.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(centre.dec, 0, accuracy: 1e-9)
        // image (199, 99) is 100 px right of CRPIX → 100 arcsec west at the equator
        let east = try XCTUnwrap(wcs.pixelToSky(imageX: 199, imageY: 99))
        XCTAssertEqual(east.ra, 180 - 100.0 / 3600, accuracy: 1e-6)
    }

    func testUnsupportedProjectionReturnsNil() throws {
        // COE (Conic Equal Area) isn't implemented — should be rejected.
        let header = try parseHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "CTYPE1  = 'RA---COE'         ",
            "CTYPE2  = 'DEC--COE'         ",
            "CRPIX1  = \(format(1.0))",
            "CRPIX2  = \(format(1.0))",
            "CRVAL1  = \(format(0.0))",
            "CRVAL2  = \(format(0.0))",
            "CD1_1   = \(format(-1.0))",
            "CD1_2   = \(format(0.0))",
            "CD2_1   = \(format(0.0))",
            "CD2_2   = \(format(1.0))",
            "END",
        ])
        XCTAssertNil(WCS(header: header))
    }

    // MARK: - Helpers

    private func parseHeader(_ cards: [String]) throws -> FITSHeader {
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let block = 2880
        if s.count % block != 0 {
            s += String(repeating: " ", count: block - s.count % block)
        }
        let data = Data(s.utf8)
        let (header, _) = try XCTUnwrap(FITSHeader.parse(in: data, at: 0))
        return header
    }

    private func projectionHeader(
        ctype1: String,
        ctype2: String,
        crpix: (Double, Double),
        crval: (Double, Double),
        cd: (Double, Double, Double, Double)
    ) -> [String] {
        [
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "CTYPE1  = '\(ctype1)'         ",
            "CTYPE2  = '\(ctype2)'         ",
            "CRPIX1  = \(format(crpix.0))",
            "CRPIX2  = \(format(crpix.1))",
            "CRVAL1  = \(format(crval.0))",
            "CRVAL2  = \(format(crval.1))",
            "CD1_1   = \(format(cd.0))",
            "CD1_2   = \(format(cd.1))",
            "CD2_1   = \(format(cd.2))",
            "CD2_2   = \(format(cd.3))",
            "END",
        ]
    }

    private func tanHeader(
        crpix: (Double, Double),
        crval: (Double, Double),
        cd: (Double, Double, Double, Double)
    ) -> [String] {
        [
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'         ",
            "CTYPE2  = 'DEC--TAN'         ",
            "CRPIX1  = \(format(crpix.0))",
            "CRPIX2  = \(format(crpix.1))",
            "CRVAL1  = \(format(crval.0))",
            "CRVAL2  = \(format(crval.1))",
            "CD1_1   = \(format(cd.0))",
            "CD1_2   = \(format(cd.1))",
            "CD2_1   = \(format(cd.2))",
            "CD2_2   = \(format(cd.3))",
            "END",
        ]
    }

    private func format(_ d: Double) -> String {
        String(format: "%20.10f", d)
    }
}
