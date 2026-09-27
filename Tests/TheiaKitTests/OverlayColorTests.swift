import XCTest
@testable import TheiaKit

final class OverlayColorTests: XCTestCase {
    func testNamedAndHexRegionColors() {
        XCTAssertEqual(OverlayColor.parse("  MAGENTA "),
                       OverlayColor(red: 1, green: 0, blue: 1))
        XCTAssertEqual(OverlayColor.parse("#1a80FF"),
                       OverlayColor(red: 26.0 / 255, green: 128.0 / 255, blue: 1))
        XCTAssertEqual(OverlayColor.parse("purple"),
                       OverlayColor(red: 0.42, green: 0.32, blue: 0.78))
        XCTAssertNil(OverlayColor.parse("#xyzxyz"))
        XCTAssertNil(OverlayColor.parse("#12345"))
        XCTAssertNil(OverlayColor.parse(nil))
    }
}
