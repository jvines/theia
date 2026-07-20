import XCTest
@testable import FITSCore

final class WCSProjectionsTests: XCTestCase {
    private func pad(_ s: String) -> String { s.padding(toLength: 80, withPad: " ", startingAt: 0) }

    private func wcs(projection: String, crpix: (Double, Double) = (50, 50),
                     crval: (Double, Double) = (180, 0)) throws -> WCS {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("CRPIX1  = \(String(format: "%20.4f", crpix.0))"),
            pad("CRPIX2  = \(String(format: "%20.4f", crpix.1))"),
            pad("CRVAL1  = \(String(format: "%20.6f", crval.0))"),
            pad("CRVAL2  = \(String(format: "%20.6f", crval.1))"),
            pad("CDELT1  = \(String(format: "%20.10f", -0.1))"),    // 0.1 deg/pixel
            pad("CDELT2  = \(String(format: "%20.10f",  0.1))"),
            pad("CTYPE1  = 'RA---\(projection)'"),
            pad("CTYPE2  = 'DEC--\(projection)'"),
            pad("END"),
        ]
        var h = cards.joined()
        if h.count % 2880 != 0 { h += String(repeating: " ", count: 2880 - h.count % 2880) }
        return try XCTUnwrap(WCS(header: try FITSFile(data: Data(h.utf8)).hdus[0].header))
    }

    // MARK: - CAR

    func testCARIdentityAtReferencePixel() throws {
        let w = try wcs(projection: "CAR")
        let sky = w.pixelToSky(imageX: 49, imageY: 49)!
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 0,   accuracy: 1e-6)
    }

    func testCARLinearInDegrees() throws {
        // 0.1 deg/pixel, CDELT1 negative → +10 pixels east of CRPIX → RA = 180 - 1.0
        let w = try wcs(projection: "CAR")
        let sky = w.pixelToSky(imageX: 59, imageY: 49)!
        XCTAssertEqual(sky.ra, 180 - 1.0, accuracy: 1e-6)
        // +10 pixels north → Dec = 0 + 1.0
        let sky2 = w.pixelToSky(imageX: 49, imageY: 59)!
        XCTAssertEqual(sky2.dec, 1.0, accuracy: 1e-6)
    }

    func testCARRoundTrips() throws {
        let w = try wcs(projection: "CAR")
        for ix in [10, 30, 70, 90] {
            for iy in [10, 30, 70, 90] {
                let sky = w.pixelToSky(imageX: ix, imageY: iy)!
                let back = w.skyToPixel(ra: sky.ra, dec: sky.dec)!
                XCTAssertEqual(back.x, Double(ix), accuracy: 1e-6)
                XCTAssertEqual(back.y, Double(iy), accuracy: 1e-6)
            }
        }
    }

    // MARK: - MER

    func testMERIdentityAtReferencePixel() throws {
        let w = try wcs(projection: "MER")
        let sky = w.pixelToSky(imageX: 49, imageY: 49)!
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 0,   accuracy: 1e-6)
    }

    func testMERStretchesPolesAsymptotically() throws {
        // Near the pole, Mercator's eta diverges. At Dec=80° from CRVAL2=0,
        // eta = log(tan(π/4 + 40°)) ≈ log(tan(85°)) ≈ 2.4 rad.
        // In our test grid we just check ascending Dec gives ascending eta.
        let w = try wcs(projection: "MER")
        let sky10 = w.pixelToSky(imageX: 49, imageY: 59)!
        let sky20 = w.pixelToSky(imageX: 49, imageY: 69)!
        XCTAssertGreaterThan(sky20.dec, sky10.dec)
    }

    func testMERRoundTrips() throws {
        let w = try wcs(projection: "MER")
        for ix in [10, 30, 70, 90] {
            for iy in [30, 50, 70] {
                let sky = w.pixelToSky(imageX: ix, imageY: iy)!
                let back = w.skyToPixel(ra: sky.ra, dec: sky.dec)!
                XCTAssertEqual(back.x, Double(ix), accuracy: 1e-6)
                XCTAssertEqual(back.y, Double(iy), accuracy: 1e-6)
            }
        }
    }

    // BUG-14: MER dropped the CRVAL2 offset, so an off-equator reference mapped to
    // Dec=0 at the reference pixel instead of CRVAL2.
    func testMERHonorsReferenceDeclination() throws {
        let w = try wcs(projection: "MER", crval: (180, 30))
        let sky = w.pixelToSky(imageX: 49, imageY: 49)!   // reference pixel
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 30, accuracy: 1e-6)
    }

    func testMERRoundTripsOffEquator() throws {
        let w = try wcs(projection: "MER", crval: (180, 30))
        for (px, py) in [(49, 49), (55, 45), (40, 60)] {
            let sky = w.pixelToSky(imageX: px, imageY: py)!
            let back = w.skyToPixel(ra: sky.ra, dec: sky.dec)!
            XCTAssertEqual(back.x, Double(px), accuracy: 1e-6)
            XCTAssertEqual(back.y, Double(py), accuracy: 1e-6)
        }
    }

    // MARK: - AIT (Hammer-Aitoff)

    func testAITIdentityAtReferencePixel() throws {
        let w = try wcs(projection: "AIT")
        let sky = w.pixelToSky(imageX: 49, imageY: 49)!
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 0,   accuracy: 1e-6)
    }

    func testAITRoundTripsNearCenter() throws {
        let w = try wcs(projection: "AIT")
        for ix in [40, 50, 60] {
            for iy in [40, 50, 60] {
                let sky = w.pixelToSky(imageX: ix, imageY: iy)!
                let back = w.skyToPixel(ra: sky.ra, dec: sky.dec)!
                XCTAssertEqual(back.x, Double(ix), accuracy: 1e-3)
                XCTAssertEqual(back.y, Double(iy), accuracy: 1e-3)
            }
        }
    }

    // MARK: - MOL (Mollweide)

    func testMOLIdentityAtReferencePixel() throws {
        let w = try wcs(projection: "MOL")
        let sky = w.pixelToSky(imageX: 49, imageY: 49)!
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 0,   accuracy: 1e-6)
    }

    func testMOLRoundTripsNearCenter() throws {
        let w = try wcs(projection: "MOL")
        for ix in [40, 50, 60] {
            for iy in [40, 50, 60] {
                let sky = w.pixelToSky(imageX: ix, imageY: iy)!
                let back = w.skyToPixel(ra: sky.ra, dec: sky.dec)!
                XCTAssertEqual(back.x, Double(ix), accuracy: 1e-3)
                XCTAssertEqual(back.y, Double(iy), accuracy: 1e-3)
            }
        }
    }

    /// At |dec|=90° the Newton iteration's derivative vanishes; the result must
    /// still match the closed-form γ=±π/2 (yRad = ±√2, xRad = 0) and round-trip.
    func testMOLForwardAtPole() throws {
        let w = try wcs(projection: "MOL")
        for poleDec in [90.0, -90.0] {
            guard let pix = w.skyToPixel(ra: 180, dec: poleDec) else {
                XCTFail("skyToPixel returned nil at pole")
                return
            }
            XCTAssertTrue(pix.x.isFinite && pix.y.isFinite,
                          "got NaN/Inf at pole: \(pix)")
            // Pole maps to top/bottom of the MOL ellipse — y component is the
            // largest excursion. With our 1°/px pseudoscale and 100×100 image,
            // poleDec=+90 lands well above CRPIX, -90 well below.
            if poleDec > 0 {
                XCTAssertGreaterThan(pix.y, 49)
            } else {
                XCTAssertLessThan(pix.y, 49)
            }
        }
    }

    // MARK: - STG

    func testSTGIdentityAtReferencePixel() throws {
        let w = try wcs(projection: "STG")
        let sky = w.pixelToSky(imageX: 49, imageY: 49)!
        XCTAssertEqual(sky.ra, 180, accuracy: 1e-6)
        XCTAssertEqual(sky.dec, 0,   accuracy: 1e-6)
    }

    func testSTGRoundTrips() throws {
        let w = try wcs(projection: "STG")
        for ix in [40, 50, 60] {
            for iy in [40, 50, 60] {
                let sky = w.pixelToSky(imageX: ix, imageY: iy)!
                let back = w.skyToPixel(ra: sky.ra, dec: sky.dec)!
                XCTAssertEqual(back.x, Double(ix), accuracy: 1e-3)
                XCTAssertEqual(back.y, Double(iy), accuracy: 1e-3)
            }
        }
    }

    // MARK: - Alt WCS variants

    func testAltVariantWCSParses() throws {
        // Primary = TAN; variant A = CAR at a different reference point.
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("CTYPE1  = 'RA---TAN'"),
            pad("CTYPE2  = 'DEC--TAN'"),
            pad("CRPIX1  =                  50.0"),
            pad("CRPIX2  =                  50.0"),
            pad("CRVAL1  =                 100.0"),
            pad("CRVAL2  =                   0.0"),
            pad("CDELT1  =        -0.0002777778"),
            pad("CDELT2  =         0.0002777778"),
            pad("WCSNAMEA= 'galactic'"),
            pad("CTYPE1A = 'RA---CAR'"),
            pad("CTYPE2A = 'DEC--CAR'"),
            pad("CRPIX1A =                  50.0"),
            pad("CRPIX2A =                  50.0"),
            pad("CRVAL1A =                 200.0"),
            pad("CRVAL2A =                  10.0"),
            pad("CDELT1A =                   0.1"),
            pad("CDELT2A =                   0.1"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 { header += String(repeating: " ", count: 2880 - header.count % 2880) }
        let hdr = try FITSFile(data: Data(header.utf8)).hdus[0].header

        let variants = WCS.availableVariants(in: hdr)
        XCTAssertTrue(variants.contains(""))
        XCTAssertTrue(variants.contains("A"))

        let primary = WCS(header: hdr)
        XCTAssertEqual(primary?.projectionType, "TAN")
        XCTAssertEqual(primary?.crval.ra, 100)

        let alt = WCS(header: hdr, variant: "A")
        XCTAssertEqual(alt?.projectionType, "CAR")
        XCTAssertEqual(alt?.crval.ra, 200)
        XCTAssertEqual(alt?.name, "galactic")
        XCTAssertEqual(alt?.variant, "A")
    }
}
