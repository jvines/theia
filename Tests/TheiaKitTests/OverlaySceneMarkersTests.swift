import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class OverlaySceneMarkersTests: XCTestCase {
    private let mapping = ViewMapping(transform: ViewTransform(scale: 2, centre: .zero),
                                      viewSize: SIMD2(100, 100), backingScale: 1)

    func testCrosshairMapsImagePointAndKeepsMarkerSizeInViewPoints() {
        let primitives = OverlayScene.crosshair(at: SIMD2(5, 0), mapping: mapping)
        XCTAssertTrue(primitives.contains(.ellipse(center: SIMD2(60, 50), radiusX: 3, radiusY: 3,
                                                  stroke: .init(red: 1, green: 1, blue: 0),
                                                  opacity: 0.85, lineWidth: 1)))
        XCTAssertTrue(primitives.contains(.segments([
            .init(from: SIMD2(46, 50), to: SIMD2(74, 50)),
            .init(from: SIMD2(60, 36), to: SIMD2(60, 64)),
        ], stroke: .init(red: 1, green: 1, blue: 0),
           opacity: 0.85, lineWidth: 1.2, dash: [])))
    }

    func testProfileLineMapsEndpointsAndKeepsImageLengthLabel() {
        let primitives = OverlayScene.profile(.line(from: SIMD2(0, 0), to: SIMD2(10, 0)),
                                              mapping: mapping)
        let gold = OverlayColor(red: 1, green: 0.85, blue: 0.30)
        XCTAssertTrue(primitives.contains(.segments([
            .init(from: SIMD2(50, 50), to: SIMD2(70, 50)),
        ], stroke: gold, opacity: 1, lineWidth: 1.5, dash: [4, 3])))
        XCTAssertTrue(primitives.contains(.text("10.0 px", at: SIMD2(60, 50),
                                              color: gold, size: 10, opacity: 1)))
    }

    func testContoursMapCachedImageSegments() {
        let leveled = Contours.segments(values: [0, 1, 0, 1], width: 2, height: 2,
                                         levels: [0.5])
        let primitives = OverlayScene.contours(leveled, mapping: mapping)
        XCTAssertEqual(primitives.count, 1)
        guard case .segments(let lines, let stroke, let opacity, let width, let dash) = primitives[0] else {
            return XCTFail("expected contour segments")
        }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(stroke, OverlayColor(red: 0, green: 1, blue: 1))
        XCTAssertEqual(opacity, 1)
        XCTAssertEqual(width, 1)
        XCTAssertEqual(dash, [])
        XCTAssertTrue(lines.allSatisfy { $0.from.x >= 50 && $0.to.x <= 52 })
    }
}
