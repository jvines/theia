import XCTest
@testable import XPABridge

final class XPABridgeTests: XCTestCase {
    func testLinkedVersion() {
        XCTAssertEqual(XPABridge.version, "2.1.20")
    }

    /// Proves libxpa links and an access point can be created + freed in-process.
    func testCanCreateAccessPoint() {
        XCTAssertTrue(XPABridge.canCreateAccessPoint())
    }
}
