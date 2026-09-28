import AppKit
import XCTest
@testable import FITSViewerApp

final class RemoteTransferWindowTests: XCTestCase {
    @MainActor func testCancelButtonCancelsOnlyOnce() {
        _ = NSApplication.shared
        var cancellations = 0
        let window = RemoteTransferWindow(filename: "image.fits", host: "cluster.example") {
            cancellations += 1
        }
        window.cancelButton.performClick(nil)
        window.dismiss()
        XCTAssertEqual(cancellations, 1)
    }
}
