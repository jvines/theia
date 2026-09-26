import XCTest
#if canImport(simd)
import simd
#endif
@testable import FITSCore

final class CompassAndScaleBarTests: XCTestCase {
    func testCompassForStandardEastLeftNorthUpImage() throws {
        // CD1_1 < 0 means image x increases west; CD2_2 > 0 means image y increases north.
        let header = try parseHeader(tanHeader(
            crpix: (1, 1), crval: (0, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let compass = wcs.compass
        // East unit vector points in -x direction.
        XCTAssertEqual(compass.eastDirectionImage.x, -1, accuracy: 1e-9)
        XCTAssertEqual(compass.eastDirectionImage.y, 0, accuracy: 1e-9)
        // North unit vector points in +y direction.
        XCTAssertEqual(compass.northDirectionImage.x, 0, accuracy: 1e-9)
        XCTAssertEqual(compass.northDirectionImage.y, 1, accuracy: 1e-9)
    }

    func testCompassForRotated45DegreeImage() throws {
        // Rotated CD matrix: 45° rotation of the standard orientation.
        // Build via CDELT + CROTA so the rotation is explicit.
        let header = try parseHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'         ",
            "CTYPE2  = 'DEC--TAN'         ",
            "CRPIX1  = \(format(1.0))",
            "CRPIX2  = \(format(1.0))",
            "CRVAL1  = \(format(0.0))",
            "CRVAL2  = \(format(0.0))",
            "CDELT1  = \(format(-1.0 / 3600))",
            "CDELT2  = \(format(1.0 / 3600))",
            "CROTA2  = \(format(45.0))",
            "END",
        ])
        let wcs = try XCTUnwrap(WCS(header: header))
        let compass = wcs.compass
        // East and North should still be perpendicular unit vectors.
        let east = compass.eastDirectionImage
        let north = compass.northDirectionImage
        XCTAssertEqual((east.x * east.x + east.y * east.y).squareRoot(), 1, accuracy: 1e-9)
        XCTAssertEqual((north.x * north.x + north.y * north.y).squareRoot(), 1, accuracy: 1e-9)
        XCTAssertEqual(east.x * north.x + east.y * north.y, 0, accuracy: 1e-9)
    }

    func testPixelScaleArcsecPerPixel() throws {
        let header = try parseHeader(tanHeader(
            crpix: (1, 1), crval: (0, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        XCTAssertEqual(wcs.pixelScaleArcsec, 1, accuracy: 1e-6)
    }

    func testNiceAngularExtentForScaleBar() {
        // viewportScale = 2 points/pixel, pixelScale = 1 arcsec/pixel, target 100 points.
        // Raw arcsec = 100 * 1 / 2 = 50 arcsec → nice = 50 arcsec
        // length points = 50 * 2 / 1 = 100 points
        let result = ScaleBar.niceAngularExtent(
            viewPointsTarget: 100,
            pixelScaleArcsec: 1,
            viewportScale: 2
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.lengthArcsec, 50, accuracy: 1e-9)
        XCTAssertEqual(result!.lengthPoints, 100, accuracy: 1e-9)
    }

    func testNiceAngularExtentReturnsNilForZeroScale() {
        XCTAssertNil(ScaleBar.niceAngularExtent(
            viewPointsTarget: 100,
            pixelScaleArcsec: 0,
            viewportScale: 1
        ))
    }

    // MARK: - Helpers

    private func parseHeader(_ cards: [String]) throws -> FITSHeader {
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let block = 2880
        if s.count % block != 0 {
            s += String(repeating: " ", count: block - s.count % block)
        }
        let (h, _) = try XCTUnwrap(FITSHeader.parse(in: Data(s.utf8), at: 0))
        return h
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

    private func format(_ d: Double) -> String { String(format: "%20.10f", d) }
}
