import XCTest
@testable import FITSCore

final class GaiaCSVTests: XCTestCase {
    func testParsesValidGaiaCSV() {
        let csv = """
        ra,dec,phot_g_mean_mag
        180.001,0.0,15.32
        180.002,0.001,14.50
        180.003,-0.001,16.77
        """
        let sources = CatalogResult.parseGaiaCSV(csv)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0].ra, 180.001, accuracy: 1e-9)
        XCTAssertEqual(sources[0].dec, 0.0, accuracy: 1e-9)
        XCTAssertEqual(sources[0].gMag, 15.32)
    }

    func testHandlesMissingMagColumn() {
        let csv = """
        ra,dec
        10.0,20.0
        """
        let sources = CatalogResult.parseGaiaCSV(csv)
        XCTAssertEqual(sources.count, 1)
        XCTAssertNil(sources[0].gMag)
    }

    func testIgnoresMalformedRows() {
        let csv = """
        ra,dec,phot_g_mean_mag
        180.0,0.0,15.0
        not_a_number,foo,bar
        181.0,1.0,
        """
        let sources = CatalogResult.parseGaiaCSV(csv)
        XCTAssertEqual(sources.count, 2)
        XCTAssertNil(sources[1].gMag)
    }

    func testEmptyCSVReturnsEmpty() {
        XCTAssertTrue(CatalogResult.parseGaiaCSV("").isEmpty)
    }

    func testHeaderOnlyReturnsEmpty() {
        XCTAssertTrue(CatalogResult.parseGaiaCSV("ra,dec,phot_g_mean_mag").isEmpty)
    }
}
