import XCTest
@testable import FITSCore

final class WCSSIPTests: XCTestCase {
    private func pad(_ s: String) -> String { s.padding(toLength: 80, withPad: " ", startingAt: 0) }

    /// TAN-SIP WCS with a tiny quadratic A_2_0 distortion only. Inverse coefficients
    /// AP_2_0 is approximately the negation (small-distortion limit).
    private func wcs() throws -> WCS {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("CRPIX1  =                  50.0"),
            pad("CRPIX2  =                  50.0"),
            pad("CRVAL1  =                 180.0"),
            pad("CRVAL2  =                   0.0"),
            pad("CDELT1  =        -0.0002777778"),
            pad("CDELT2  =         0.0002777778"),
            pad("CTYPE1  = 'RA---TAN-SIP'"),
            pad("CTYPE2  = 'DEC--TAN-SIP'"),
            pad("A_ORDER =                    2"),
            pad("B_ORDER =                    2"),
            pad("A_2_0   =              0.001"),
            pad("AP_ORDER=                    2"),
            pad("BP_ORDER=                    2"),
            pad("AP_2_0  =             -0.001"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        return try XCTUnwrap(WCS(header: try FITSFile(data: Data(header.utf8)).hdus[0].header))
    }

    func testRecognisesTANSIPCtype() throws {
        XCTAssertEqual(try wcs().projectionType, "TAN")  // base projection
    }

    func testForwardSIPShiftsPixelOffCenter() throws {
        // Same WCS but without the SIP A_2_0 — compare positions of a pixel 10 from CRPIX
        // along x. Both should be near each other; the SIP version offset by the distortion.
        let withSIP = try wcs()
        let plainCards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("CRPIX1  =                  50.0"),
            pad("CRPIX2  =                  50.0"),
            pad("CRVAL1  =                 180.0"),
            pad("CRVAL2  =                   0.0"),
            pad("CDELT1  =        -0.0002777778"),
            pad("CDELT2  =         0.0002777778"),
            pad("CTYPE1  = 'RA---TAN'"),
            pad("CTYPE2  = 'DEC--TAN'"),
            pad("END"),
        ]
        var ph = plainCards.joined()
        if ph.count % 2880 != 0 { ph += String(repeating: " ", count: 2880 - ph.count % 2880) }
        let plain = try XCTUnwrap(WCS(header: try FITSFile(data: Data(ph.utf8)).hdus[0].header))

        let pix = (x: 59, y: 49)  // 10 px right of CRPIX (0-based)
        guard let sSky = withSIP.pixelToSky(imageX: pix.x, imageY: pix.y),
              let pSky = plain.pixelToSky(imageX: pix.x, imageY: pix.y) else {
            XCTFail("WCS conversion failed"); return
        }
        // With A_2_0=0.001 and dx=10, the SIP-corrected u = 10 + 0.001 * 100 = 10.1.
        // So sky position differs from the plain WCS by ~ 0.1 px worth of RA = 0.0277778″.
        XCTAssertNotEqual(sSky.ra, pSky.ra, accuracy: 1e-9)
        let diffArcsec = abs((sSky.ra - pSky.ra) * 3600 / cos(pSky.dec * .pi / 180))
        XCTAssertEqual(diffArcsec, 0.1, accuracy: 0.02)
    }

    /// TAN-SIP with FORWARD SIP (A/B) only — no inverse AP/BP, as HST/ZTF/PS1
    /// headers commonly ship. skyToPixel must still invert pixelToSky.
    private func forwardOnlyWCS() throws -> WCS {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("CRPIX1  =                  50.0"),
            pad("CRPIX2  =                  50.0"),
            pad("CRVAL1  =                 180.0"),
            pad("CRVAL2  =                   0.0"),
            pad("CDELT1  =        -0.0002777778"),
            pad("CDELT2  =         0.0002777778"),
            pad("CTYPE1  = 'RA---TAN-SIP'"),
            pad("CTYPE2  = 'DEC--TAN-SIP'"),
            pad("A_ORDER =                    2"),
            pad("B_ORDER =                    2"),
            pad("A_2_0   =              0.001"),
            pad("A_0_2   =              0.0005"),
            pad("A_1_1   =              0.0003"),
            pad("B_2_0   =              0.0004"),
            pad("B_0_2   =              0.0008"),
            pad("B_1_1   =              0.0006"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 { header += String(repeating: " ", count: 2880 - header.count % 2880) }
        return try XCTUnwrap(WCS(header: try FITSFile(data: Data(header.utf8)).hdus[0].header))
    }

    func testForwardOnlySIPInvertsNumerically() throws {
        let w = try forwardOnlyWCS()
        XCTAssertNil(w.sipInverse, "test premise: no AP/BP inverse coefficients")
        XCTAssertNotNil(w.sipForward)
        // Round-trip several pixels including a far corner (where the distortion is
        // several px) — skyToPixel(pixelToSky(p)) must return p to < 0.01 px.
        for (px, py) in [(50, 50), (65, 45), (10, 90), (0, 0), (99, 99)] {
            guard let sky = w.pixelToSky(imageX: px, imageY: py),
                  let back = w.skyToPixel(ra: sky.ra, dec: sky.dec) else {
                XCTFail("round trip failed at (\(px),\(py))"); return
            }
            XCTAssertEqual(back.x, Double(px), accuracy: 0.01, "x at (\(px),\(py))")
            XCTAssertEqual(back.y, Double(py), accuracy: 0.01, "y at (\(px),\(py))")
        }
    }

    func testInverseSIPRoundTripsApproximately() throws {
        let w = try wcs()
        let inX = 65, inY = 45
        guard let sky = w.pixelToSky(imageX: inX, imageY: inY),
              let back = w.skyToPixel(ra: sky.ra, dec: sky.dec) else {
            XCTFail("round trip failed"); return
        }
        // First-order AP_2_0 inverse is approximate; demand ~0.05 px accuracy.
        XCTAssertEqual(back.x, Double(inX), accuracy: 0.05)
        XCTAssertEqual(back.y, Double(inY), accuracy: 0.05)
    }
}
