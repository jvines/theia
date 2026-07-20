import XCTest
@testable import FITSCore

final class SkyCoordinateFormatterTests: XCTestCase {
    func testFormatRAZero() {
        XCTAssertEqual(SkyCoordinateFormatter.formatRA(0), "00:00:00.0")
    }

    func testFormatRA15DegreesIsOneHour() {
        XCTAssertEqual(SkyCoordinateFormatter.formatRA(15), "01:00:00.0")
    }

    func testFormatRA180DegreesIsTwelveHours() {
        XCTAssertEqual(SkyCoordinateFormatter.formatRA(180), "12:00:00.0")
    }

    func testFormatDecZero() {
        XCTAssertEqual(SkyCoordinateFormatter.formatDec(0), "+00:00:00.0")
    }

    func testFormatDecPositiveSubdegrees() {
        // 45.5° = 45° 30' 00.0"
        XCTAssertEqual(SkyCoordinateFormatter.formatDec(45.5), "+45:30:00.0")
    }

    func testFormatDecNegativeWithArcseconds() {
        // -30.5° = -30° 30' 00.0"
        XCTAssertEqual(SkyCoordinateFormatter.formatDec(-30.5), "-30:30:00.0")
    }
}
