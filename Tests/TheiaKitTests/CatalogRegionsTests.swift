import XCTest
import FITSCore
@testable import TheiaKit

final class CatalogRegionsTests: XCTestCase {
    func testGaiaSourcesBecomeSkyFrameRegionsWithMagnitudeMarkers() {
        let regions = CatalogRegions.fromGaia([
            GaiaSource(ra: 12.5, dec: -3.25, gMag: 10),
            GaiaSource(ra: 14, dec: 2),
            GaiaSource(ra: .nan, dec: 2, gMag: 8),
        ])
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].frame, .fk5)
        XCTAssertEqual(regions[0].attributes["color"], "cyan")
        XCTAssertEqual(regions[0].attributes["tag"], "Gaia")
        XCTAssertEqual(regions[0].attributes["text"], "G=10.0")
        XCTAssertNil(regions[1].attributes["text"])
        if case .circle(let center, let radius) = regions[0].shape {
            XCTAssertEqual(center.x, 12.5)
            XCTAssertEqual(center.y, -3.25)
            XCTAssertEqual(radius.value, 8)
        } else {
            XCTFail("Expected a circular Gaia marker")
        }
    }
}
