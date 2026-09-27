import XCTest
@testable import FITSViewerApp

@MainActor final class PixelTableBridgeTests: XCTestCase {
    func testImageRevisionNotifiesOpenPanel() {
        let bridge = PixelTableCursorBridge()
        expectation(forNotification: PixelTableCursorBridge.cursorChanged, object: bridge)
        bridge.imageRevision = 1
        waitForExpectations(timeout: 1)
    }
}
