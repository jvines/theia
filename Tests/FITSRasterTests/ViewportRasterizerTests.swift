import XCTest
import FITSCore
@testable import FITSRaster

final class ViewportRasterizerTests: XCTestCase {
    func testNativeRasterHasFITSPixelOneOneAtBottomLeft() {
        let display = DisplayImage(
            image: FITSImage.fromFloat32(pixels: [0, 1, 2, 3], width: 2, height: 2), revision: 1
        )
        let raster = ViewportRasterizer.renderNative(
            display, stretch: .linear, levels: RasterLevels(vmin: 0, vmax: 3), colorMap: .gray
        )
        XCTAssertEqual(raster.width, 2)
        XCTAssertEqual(raster.height, 2)
        let table = ColorTable(map: .gray)
        XCTAssertEqual(raster.pixel(x: 0, y: 0), table.color(for: 2.0 / 3.0))
        XCTAssertEqual(raster.pixel(x: 1, y: 0), table.color(for: 1))
        XCTAssertEqual(raster.pixel(x: 0, y: 1), table.color(for: 0))
        XCTAssertEqual(raster.pixel(x: 1, y: 1), table.color(for: 1.0 / 3.0))
    }

    func testViewportUsesNearestPixelAtTiesAndBackgroundOutside() {
        let display = DisplayImage(
            image: FITSImage.fromFloat32(pixels: [0, 1], width: 2, height: 1), revision: 1
        )
        let mapping = ViewMapping(
            transform: ViewTransform(scale: 2, centre: SIMD2(0.5, 0)),
            viewSize: SIMD2(8, 2), backingScale: 1
        )
        let raster = ViewportRasterizer.renderViewport(
            display, mapping: mapping, width: 8, height: 2,
            stretch: .linear, levels: RasterLevels(vmin: 0, vmax: 1), colorMap: .gray,
            background: RGBA8(r: 12, g: 34, b: 56)
        )
        XCTAssertEqual(raster.pixel(x: 0, y: 0), RGBA8(r: 12, g: 34, b: 56))
        XCTAssertEqual(raster.pixel(x: 3, y: 0), .opaqueBlack)
        XCTAssertEqual(raster.pixel(x: 4, y: 0), RGBA8(r: 255, g: 255, b: 255))
    }

    func testSampleStepRendersReducedResolutionAtBlockCentres() {
        let display = DisplayImage(
            image: FITSImage.fromFloat32(pixels: [0, 1, 2, 3], width: 4, height: 1), revision: 1
        )
        let mapping = ViewMapping(
            transform: ViewTransform(scale: 1, centre: SIMD2(1.5, 0)),
            viewSize: SIMD2(4, 1), backingScale: 1
        )
        let raster = ViewportRasterizer.renderViewport(
            display, mapping: mapping, width: 4, height: 1, sampleStep: 2,
            stretch: .linear, levels: RasterLevels(vmin: 0, vmax: 3), colorMap: .gray
        )
        XCTAssertEqual(raster.width, 2)
        XCTAssertEqual(raster.height, 1)
        XCTAssertEqual(raster.pixel(x: 0, y: 0), ColorTable(map: .gray).color(for: 1.0 / 3.0))
        XCTAssertEqual(raster.pixel(x: 1, y: 0), ColorTable(map: .gray).color(for: 1))
    }

    func testPartialFinalBlockSamplesInsideViewport() {
        let display = DisplayImage(
            image: FITSImage.fromFloat32(pixels: [0, 0, 0, 0, 1], width: 5, height: 1), revision: 1
        )
        let mapping = ViewMapping(
            transform: ViewTransform(scale: 1, centre: SIMD2(2, 0)),
            viewSize: SIMD2(5, 1), backingScale: 1
        )
        let raster = ViewportRasterizer.renderViewport(
            display, mapping: mapping, width: 5, height: 1, sampleStep: 2,
            stretch: .linear, levels: RasterLevels(vmin: 0, vmax: 1), colorMap: .gray
        )
        XCTAssertEqual(raster.pixel(x: 2, y: 0), RGBA8(r: 255, g: 255, b: 255))
    }
}
