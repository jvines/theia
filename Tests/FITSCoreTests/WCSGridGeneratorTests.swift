import XCTest
@testable import FITSCore

final class WCSGridGeneratorTests: XCTestCase {
    func testNiceTickSpacingChoosesOnesTwosOrFives() {
        // range 10 with ~5 ticks → spacing 2
        XCTAssertEqual(WCSGridGenerator.niceTickSpacing(range: 10, targetTicks: 5), 2, accuracy: 1e-12)
        // range 7 → spacing 1
        XCTAssertEqual(WCSGridGenerator.niceTickSpacing(range: 7, targetTicks: 5), 1, accuracy: 1e-12)
        // range 50 → spacing 10
        XCTAssertEqual(WCSGridGenerator.niceTickSpacing(range: 50, targetTicks: 5), 10, accuracy: 1e-12)
        // range 0.05 → spacing 0.01
        XCTAssertEqual(WCSGridGenerator.niceTickSpacing(range: 0.05, targetTicks: 5), 0.01, accuracy: 1e-12)
    }

    func testGridlinesProducesBothRAAndDecLines() throws {
        // 100×100 image, 1 arcsec/pix scale centred on (180°, 0°).
        let header = try parseHeader(tanHeader(
            crpix: (50, 50),
            crval: (180, 0),
            cd: (-1.0 / 3600, 0, 0, 1.0 / 3600)
        ))
        let wcs = try XCTUnwrap(WCS(header: header))
        let lines = WCSGridGenerator.gridlines(wcs: wcs, imageWidth: 100, imageHeight: 100)
        XCTAssertGreaterThan(lines.filter { $0.kind == .ra }.count, 0)
        XCTAssertGreaterThan(lines.filter { $0.kind == .dec }.count, 0)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.pixelPoints.count, 2)
        }
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
