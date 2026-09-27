import XCTest
@testable import FITSCore

final class WCSReprojectTests: XCTestCase {
    func testReprojectOntoSameWCSPreservesPixelValuesWithinBilinearTolerance() throws {
        let pixels: [Float] = (0..<100).map { Float($0) }   // 10×10 ramp
        let source = FITSImage.fromFloat32(pixels: pixels, width: 10, height: 10)
        let header = try parseHeader(tanHeader(
            crpix: (5, 5), crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let out = WCSReproject.reproject(
            source: source, sourceWCS: wcs,
            targetWCS: wcs, targetWidth: 10, targetHeight: 10
        )
        XCTAssertEqual(out.width, 10)
        XCTAssertEqual(out.height, 10)
        // Identity reproject: each target pixel should match its source pixel within
        // bilinear interpolation noise (which is zero here since sampling lands on integers).
        for y in 0..<10 {
            for x in 0..<10 {
                XCTAssertEqual(
                    out.physicalValue(x: x, y: y),
                    source.physicalValue(x: x, y: y),
                    accuracy: 1e-3,
                    "mismatch at (\(x),\(y))"
                )
            }
        }
    }

    func testReprojectFromOffsetTargetSamplesTheRightSourcePixel() throws {
        // Source: 10×10 ramp, CRPIX=(5,5), CRVAL=(180,0), 1″/pix.
        let pixels: [Float] = (0..<100).map { Float($0) }
        let source = FITSImage.fromFloat32(pixels: pixels, width: 10, height: 10)
        let sourceWCS = try XCTUnwrap(WCS(header: parseHeader(tanHeader(
            crpix: (5, 5), crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))))
        // Target: same scale + projection, but CRPIX shifted by (+2, +1) — same physical
        // origin. So target pixel (4, 4) is at sky (180°, 0°), same as source pixel (4, 4).
        let targetWCS = try XCTUnwrap(WCS(header: parseHeader(tanHeader(
            crpix: (7, 6), crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))))
        let out = WCSReproject.reproject(
            source: source, sourceWCS: sourceWCS,
            targetWCS: targetWCS, targetWidth: 10, targetHeight: 10
        )
        // Target pixel (6, 5) (FITS 7, 6) is at CRVAL → maps to source pixel (4, 4) (FITS 5, 5).
        XCTAssertEqual(out.physicalValue(x: 6, y: 5), source.physicalValue(x: 4, y: 4), accuracy: 1e-3)
    }

    func testReprojectOutOfBoundsTargetPixelsAreNaN() throws {
        let pixels = [Float](repeating: 1, count: 4 * 4)
        let source = FITSImage.fromFloat32(pixels: pixels, width: 4, height: 4)
        // Two WCSs whose footprints don't overlap.
        let sourceWCS = try XCTUnwrap(WCS(header: parseHeader(tanHeader(
            crpix: (2, 2), crval: (0, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))))
        let targetWCS = try XCTUnwrap(WCS(header: parseHeader(tanHeader(
            crpix: (2, 2), crval: (45, 45),  // far away on the sky
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))))
        let out = WCSReproject.reproject(
            source: source, sourceWCS: sourceWCS,
            targetWCS: targetWCS, targetWidth: 4, targetHeight: 4
        )
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertTrue(out.physicalValue(x: x, y: y).isNaN, "(\(x),\(y))")
            }
        }
    }

    func testReprojectConvertsGalacticTargetSkyIntoEquatorialSourceFrame() throws {
        let source = FITSImage.fromFloat32(pixels: (0..<100).map(Float.init),
                                           width: 10, height: 10)
        let sourceWCS = try XCTUnwrap(WCS(header: parseHeader(tanHeader(
            crpix: (5, 5), crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))))
        let galacticCenter = CelestialTransform.convert(lon: 180, lat: 0,
                                                        from: .icrs, to: .galactic)
        let galacticCards = tanHeader(
            crpix: (5, 5), crval: (galacticCenter.lon, galacticCenter.lat),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ).map {
            $0.replacingOccurrences(of: "RA---TAN", with: "GLON-TAN")
              .replacingOccurrences(of: "DEC--TAN", with: "GLAT-TAN")
        }
        let targetWCS = try XCTUnwrap(WCS(header: parseHeader(galacticCards)))
        XCTAssertEqual(targetWCS.nativeFrame, .galactic)

        let projected = WCSReproject.reproject(
            source: source, sourceWCS: sourceWCS, targetWCS: targetWCS,
            targetWidth: 10, targetHeight: 10
        )
        XCTAssertEqual(projected.physicalValue(x: 4, y: 4), 44, accuracy: 1e-2)
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
