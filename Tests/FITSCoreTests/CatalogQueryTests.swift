import XCTest
@testable import FITSCore

final class CatalogQueryTests: XCTestCase {
    func testAngularDistanceIsZeroForSamePoint() {
        XCTAssertEqual(
            CatalogQuery.angularDistance(ra1: 180, dec1: 30, ra2: 180, dec2: 30),
            0,
            accuracy: 1e-12
        )
    }

    func testAngularDistanceIs90AcrossEquatorToPole() {
        XCTAssertEqual(
            CatalogQuery.angularDistance(ra1: 0, dec1: 0, ra2: 0, dec2: 90),
            90,
            accuracy: 1e-9
        )
    }

    func testAngularDistanceIs180ForAntipodalPoints() {
        XCTAssertEqual(
            CatalogQuery.angularDistance(ra1: 0, dec1: 0, ra2: 180, dec2: 0),
            180,
            accuracy: 1e-9
        )
    }

    func testConeSearchReturnsImageCentreAndDiagonalRadius() throws {
        // 100x100 image, 1 arcsec/pix scale, CRPIX at centre, CRVAL=(180, 0).
        let header = try parseHeader(tanHeader(
            crpix: (50, 50),
            crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let cs = try XCTUnwrap(CatalogQuery.coneSearch(
            wcs: wcs, imageWidth: 100, imageHeight: 100
        ))
        // Center pixel is image (50, 50); FITS pixel (51, 51); 1 pixel from CRPIX,
        // so RA ≈ 180 - 1/3600, Dec ≈ +1/3600.
        XCTAssertEqual(cs.centerRA, 180 - 1.0 / 3600, accuracy: 1e-4)
        XCTAssertEqual(cs.centerDec, 1.0 / 3600, accuracy: 1e-6)
        // Farthest corner is ~sqrt(50² + 50²) ≈ 70.7 pixels = 70.7 arcsec ≈ 0.01964°.
        XCTAssertEqual(cs.radiusDeg, 70.7 / 3600, accuracy: 0.001)
    }

    func testBuildGaiaConeSearchADQLContainsCircle() {
        let query = CatalogQuery.gaiaConeSearchADQL(
            centerRA: 180.0,
            centerDec: 0.0,
            radiusDeg: 0.1,
            limit: 500
        )
        XCTAssertTrue(query.contains("SELECT TOP 500"))
        XCTAssertTrue(query.contains("FROM gaiadr3.gaia_source"))
        XCTAssertTrue(query.contains("CIRCLE('ICRS', 180.0, 0.0, 0.1)"))
    }

    // MARK: - Helpers

    private func parseHeader(_ cards: [String]) throws -> FITSHeader {
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let block = 2880
        if s.count % block != 0 {
            s += String(repeating: " ", count: block - s.count % block)
        }
        let (header, _) = try XCTUnwrap(FITSHeader.parse(in: Data(s.utf8), at: 0))
        return header
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
            "CRPIX1  = \(String(format: "%20.10f", crpix.0))",
            "CRPIX2  = \(String(format: "%20.10f", crpix.1))",
            "CRVAL1  = \(String(format: "%20.10f", crval.0))",
            "CRVAL2  = \(String(format: "%20.10f", crval.1))",
            "CD1_1   = \(String(format: "%20.10f", cd.0))",
            "CD1_2   = \(String(format: "%20.10f", cd.1))",
            "CD2_1   = \(String(format: "%20.10f", cd.2))",
            "CD2_2   = \(String(format: "%20.10f", cd.3))",
            "END",
        ]
    }
}
