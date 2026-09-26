import XCTest
import TheiaKit

final class CursorInfoTests: XCTestCase {
    func testFITSReadoutIsOneBasedWhileImageIndicesStayZeroBased() {
        let cursor = CursorInfo(imageX: 0, imageY: 9, value: 42)
        XCTAssertEqual(cursor.fitsX, 1)
        XCTAssertEqual(cursor.fitsY, 10)
        XCTAssertEqual(cursor.imageX, 0)
        XCTAssertEqual(cursor.imageY, 9)
    }
}
