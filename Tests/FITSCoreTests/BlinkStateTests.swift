import XCTest
@testable import FITSCore

final class BlinkStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    func testReturnsPrimaryAtStart() {
        let s = BlinkState(primary: 0, partner: 1, intervalSeconds: 1.0, startedAt: start)
        XCTAssertEqual(s.currentHDU(at: start), 0)
    }

    func testReturnsPartnerAfterHalfPeriod() {
        let s = BlinkState(primary: 0, partner: 1, intervalSeconds: 1.0, startedAt: start)
        let t = start.addingTimeInterval(0.6)  // past the half-period boundary
        XCTAssertEqual(s.currentHDU(at: t), 1)
    }

    func testReturnsPrimaryAfterFullPeriod() {
        let s = BlinkState(primary: 0, partner: 1, intervalSeconds: 1.0, startedAt: start)
        let t = start.addingTimeInterval(1.1)
        XCTAssertEqual(s.currentHDU(at: t), 0)
    }

    func testAlternatesEveryHalfPeriod() {
        let s = BlinkState(primary: 5, partner: 7, intervalSeconds: 2.0, startedAt: start)
        XCTAssertEqual(s.currentHDU(at: start.addingTimeInterval(0.5)), 5)   // [0, 1)
        XCTAssertEqual(s.currentHDU(at: start.addingTimeInterval(1.5)), 7)   // [1, 2)
        XCTAssertEqual(s.currentHDU(at: start.addingTimeInterval(2.5)), 5)   // [2, 3)
        XCTAssertEqual(s.currentHDU(at: start.addingTimeInterval(3.5)), 7)   // [3, 4)
    }
}
