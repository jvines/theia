import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class WCSGridCacheTests: XCTestCase {
    func testGridGeometryIsReusedUntilWCSOrImageSizeChanges() async throws {
        try await MainActor.run {
            let cache = WCSGridCache()
            let firstWCS = try makeWCS(ra: 180)
            let first = cache.gridlines(wcs: firstWCS, imageWidth: 100, imageHeight: 100)
            XCTAssertFalse(first.isEmpty)
            XCTAssertEqual(cache.gridlines(wcs: firstWCS, imageWidth: 100, imageHeight: 100), first)
            XCTAssertEqual(cache.generationCount, 1)
            _ = cache.gridlines(wcs: firstWCS, imageWidth: 101, imageHeight: 100)
            XCTAssertEqual(cache.generationCount, 2)
            _ = cache.gridlines(wcs: try makeWCS(ra: 181), imageWidth: 101, imageHeight: 100)
            XCTAssertEqual(cache.generationCount, 3)
        }
    }

    private func makeWCS(ra: Double) throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  =                 50.0", "CRPIX2  =                 50.0",
            "CRVAL1  = \(String(format: "%20.10f", ra))", "CRVAL2  =                  0.0",
            "CDELT1  =        -0.0002777778", "CDELT2  =         0.0002777778", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        let file = try FITSFile(data: Data(text.utf8))
        return try XCTUnwrap(WCS(header: file.hdus[0].header))
    }
}
