import XCTest
import Observation
import FITSCore
import TheiaKit
@testable import FITSRender

@MainActor final class OverlayObservationTests: XCTestCase {
    func testRegionOverlayBodyTracksCanvasTransform() {
        let canvas = ImageViewState()
        var invalidated = false
        withObservationTracking {
            _ = RegionOverlay(regions: [], wcs: nil, viewport: canvas).body
        } onChange: {
            invalidated = true
        }
        canvas.transform = ViewTransform(scale: 2)
        XCTAssertTrue(invalidated)
    }
}
