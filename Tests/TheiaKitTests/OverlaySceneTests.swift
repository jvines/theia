import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class OverlaySceneTests: XCTestCase {
    func testRegionGeometryIsCachedInImageSpaceAcrossPan() async {
        await MainActor.run {
            let scene = OverlayScene()
            let region = Region(shape: .circle(center: .init(x: 1, y: 1),
                                                radius: .init(value: 5, unit: .pixel)),
                                frame: .image, attributes: ["color": "#ff0000", "text": "source"])
            let initial = ViewMapping(transform: ViewTransform(scale: 2, centre: .zero),
                                      viewSize: SIMD2(100, 100), backingScale: 1)
            let first = scene.regionPrimitives([region], selectedIndex: 0, wcs: nil, mapping: initial)
            XCTAssertTrue(first.contains(.ellipse(center: SIMD2(50, 50), radiusX: 10, radiusY: 10,
                                                  stroke: .init(red: 1, green: 1, blue: 0),
                                                  opacity: 1, lineWidth: 2.4)))
            XCTAssertTrue(first.contains(.text("source", at: SIMD2(50, 40),
                                               color: .init(red: 1, green: 1, blue: 0),
                                               size: 11, opacity: 1)))
            XCTAssertEqual(scene.regionGenerationCount, 1)
            let panned = ViewMapping(transform: ViewTransform(scale: 2, centre: SIMD2(5, 0)),
                                     viewSize: SIMD2(100, 100), backingScale: 1)
            let second = scene.regionPrimitives([region], selectedIndex: 0, wcs: nil, mapping: panned)
            XCTAssertTrue(second.contains(.ellipse(center: SIMD2(40, 50), radiusX: 10, radiusY: 10,
                                                   stroke: .init(red: 1, green: 1, blue: 0),
                                                   opacity: 1, lineWidth: 2.4)))
            let zoomed = ViewMapping(transform: ViewTransform(scale: 3, centre: .zero),
                                     viewSize: SIMD2(100, 100), backingScale: 1)
            let third = scene.regionPrimitives([region], selectedIndex: 0,
                                               preview: Region(shape: .point(.init(x: 4, y: 4)), frame: .image),
                                               wcs: nil, mapping: zoomed)
            XCTAssertTrue(third.contains(.ellipse(center: SIMD2(50, 50), radiusX: 15, radiusY: 15,
                                                  stroke: .init(red: 1, green: 1, blue: 0),
                                                  opacity: 1, lineWidth: 2.4)))
            XCTAssertEqual(scene.regionGenerationCount, 1)
        }
    }

    func testRotatedBoxUsesImageSpaceAngleWhenMappedToYDownView() async {
        await MainActor.run {
            let scene = OverlayScene()
            let box = Region(shape: .box(center: .init(x: 1, y: 1),
                                          width: .init(value: 4, unit: .pixel),
                                          height: .init(value: 2, unit: .pixel), angle: 90), frame: .image)
            let mapping = ViewMapping(transform: ViewTransform(scale: 1, centre: .zero),
                                      viewSize: SIMD2(100, 100), backingScale: 1)
            let primitives = scene.regionPrimitives([box], selectedIndex: nil, wcs: nil, mapping: mapping)
            XCTAssertTrue(primitives.contains(.path(points: [SIMD2(51, 52), SIMD2(51, 48),
                                                            SIMD2(49, 48), SIMD2(49, 52)],
                                                    closed: true, stroke: .defaultRegion,
                                                    opacity: 0.85, lineWidth: 1.2)))
        }
    }

    func testRegionMutationInvalidatesGeometryButSelectionDoesNot() async {
        await MainActor.run {
            let scene = OverlayScene()
            let first = Region(shape: .point(.init(x: 2, y: 3)), frame: .image)
            let changed = Region(shape: .point(.init(x: 3, y: 3)), frame: .image,
                                 attributes: ["text": "p"])
            let mapping = ViewMapping(transform: ViewTransform(scale: 1, centre: .zero),
                                      viewSize: SIMD2(100, 100), backingScale: 1)
            _ = scene.regionPrimitives([first], selectedIndex: nil, wcs: nil, mapping: mapping)
            _ = scene.regionPrimitives([first], selectedIndex: 0, wcs: nil, mapping: mapping)
            XCTAssertEqual(scene.regionGenerationCount, 1)
            let result = scene.regionPrimitives([changed], selectedIndex: nil, wcs: nil, mapping: mapping)
            XCTAssertEqual(scene.regionGenerationCount, 2)
            XCTAssertTrue(result.contains(.ellipse(center: SIMD2(52, 48), radiusX: 3, radiusY: 3,
                                                   stroke: .defaultRegion, opacity: 0.85, lineWidth: 1.2)))
            XCTAssertTrue(result.contains(.text("p", at: SIMD2(52, 38),
                                                color: .defaultRegion, size: 11, opacity: 0.85)))
        }
    }
}
