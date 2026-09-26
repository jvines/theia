import XCTest
#if canImport(simd)
import simd
#endif
@testable import FITSCore

final class RegionEditWCSTests: XCTestCase {
    // Simple TAN WCS at RA=180°, Dec=0°, 1″/pixel, CRPIX at (50, 50) so the image
    // origin (0, 0) corresponds to sky ≈ (180.0136°, -0.0136°).
    private func wcs() throws -> WCS {
        // NAXIS=0 stub so no data block is required after the header.
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("CRPIX1  =                  50.0"),
            pad("CRPIX2  =                  50.0"),
            pad("CRVAL1  =                 180.0"),
            pad("CRVAL2  =                   0.0"),
            pad("CDELT1  =        -0.0002777778"),  // 1″/pixel
            pad("CDELT2  =         0.0002777778"),
            pad("CTYPE1  = 'RA---TAN'"),
            pad("CTYPE2  = 'DEC--TAN'"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        let file = try FITSFile(data: Data(header.utf8))
        return try XCTUnwrap(WCS(header: file.hdus[0].header))
    }

    private func pad(_ s: String) -> String { s.padding(toLength: 80, withPad: " ", startingAt: 0) }

    // fk5 circle centered at the WCS reference point (180, 0) with 5″ radius.
    private func fk5Circle() -> Region {
        Region(
            shape: .circle(
                center: .init(x: 180.0, y: 0.0),
                radius: .init(value: 5, unit: .arcsecond)
            ),
            frame: .fk5
        )
    }

    func testHitTestWCSCircleByCenter() throws {
        // CRPIX is (50, 50) 1-based; image 0-based is (49, 49).
        let hit = RegionHitTest.hit(
            in: [fk5Circle()],
            atImagePoint: SIMD2(49, 49),
            toleranceImagePixels: 3,
            wcs: try wcs()
        )
        XCTAssertEqual(hit?.handle, .move)
        XCTAssertEqual(hit?.regionIndex, 0)
    }

    func testHitTestWCSCircleByRadiusRing() throws {
        // 5″ radius ≈ 5 pixels at 1″/pixel. Click 5 pixels right of center.
        let hit = RegionHitTest.hit(
            in: [fk5Circle()],
            atImagePoint: SIMD2(54, 49),
            toleranceImagePixels: 2,
            wcs: try wcs()
        )
        XCTAssertEqual(hit?.handle, .circleRadius)
    }

    func testHitTestWCSReturnsNilWithoutWCS() throws {
        let hit = RegionHitTest.hit(
            in: [fk5Circle()],
            atImagePoint: SIMD2(49, 49),
            toleranceImagePixels: 3,
            wcs: nil
        )
        XCTAssertNil(hit)
    }

    func testApplyDragMovesWCSCircleCenter() throws {
        // Drag from (49, 49) to (59, 49): cursor moved +10 pixels in x → +10″ in sky.
        // At RA=180, +10″ in xi means RA shifts by -10″/cos(0) = -10″ ≈ -0.00277778°.
        // But for this test we'll just verify the center moved by approximately that.
        let edited = RegionEdit.apply(
            to: fk5Circle(),
            handle: .move,
            dragStartImage: SIMD2(49, 49),
            currentImage: SIMD2(59, 49),
            wcs: try wcs()
        )
        if case .circle(let c, _) = edited.shape {
            // CDELT1 is negative (FITS convention), so cursor +10 px in x → RA decreases by ~10″.
            XCTAssertEqual(c.x, 180 - 10 * 0.0002777778, accuracy: 1e-3)
            XCTAssertEqual(c.y, 0, accuracy: 1e-3)
        } else { XCTFail("expected circle") }
    }

    func testApplyDragResizesWCSCircleInArcsec() throws {
        // Outer ring at +10 pixels → ~10″ radius in fk5 frame.
        let edited = RegionEdit.apply(
            to: fk5Circle(),
            handle: .circleRadius,
            dragStartImage: SIMD2(54, 49),
            currentImage: SIMD2(59, 49),
            wcs: try wcs()
        )
        if case .circle(_, let r) = edited.shape {
            XCTAssertEqual(r.unit, Region.Distance.Unit.arcsecond)
            XCTAssertEqual(r.value, 10, accuracy: 0.5)
        } else { XCTFail("expected circle") }
    }
}
