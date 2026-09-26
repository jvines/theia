import XCTest
import FITSCore
@testable import FITSRaster

final class DisplayImageBuilderTests: XCTestCase {
    func testCancelledRequestDoesNotProduceDisplayBuffer() async {
        let builder = DisplayImageBuilder()
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 1, count: 10_000), width: 10_000, height: 1
        )
        let task = Task.detached { () -> DisplayImage? in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return await builder.build(image: image, revision: 8)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
}
