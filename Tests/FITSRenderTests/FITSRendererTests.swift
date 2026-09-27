import XCTest
import Metal
import MetalKit
import simd
import FITSCore
import FITSRaster
import TheiaKit
@testable import FITSRender

@MainActor final class FITSRendererTests: XCTestCase {
    func testInitCompilesShadersAndCreatesPipeline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        XCTAssertNil(renderer.texture)
    }

    func testDrawableResizeUpdatesCanvasSizeAndBackingScale() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let canvas = ImageViewState()
        let renderer = try FITSRenderer(device: device, viewport: canvas)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 150), device: device)
        renderer.mtkView(view, drawableSizeWillChange: CGSize(width: 400, height: 300))
        XCTAssertEqual(canvas.viewSizePoints.width, 200)
        XCTAssertEqual(canvas.viewSizePoints.height, 150)
        XCTAssertEqual(canvas.backingScale, 2)
    }

    func testCanvasVisualChangesReachRendererAndRequestRedraw() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let canvas = ImageViewState()
        let renderer = try FITSRenderer(device: device, viewport: canvas)
        let view = InteractiveMTKView(frame: CGRect(x: 0, y: 0, width: 20, height: 20), device: device)
        view.fitsRenderer = renderer
        view.needsDisplay = false
        let coordinator = FITSMetalView.Coordinator()
        coordinator.renderer = renderer
        coordinator.observeCanvas(canvas, view: view)

        canvas.stretch = .power
        canvas.stretchParameter = 0.4
        canvas.colorMap = .plasma
        canvas.vmin = 2
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(renderer.stretch, .power)
        XCTAssertEqual(renderer.stretchParameter, 0.4)
        XCTAssertEqual(renderer.colorMap, .plasma)
        XCTAssertGreaterThan(coordinator.redrawRequestCount, 0)
    }

    func testDirectCanvasStretchAndColorMapChangesAffectPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let canvas = ImageViewState(vmin: 0, vmax: 1, stretch: .power, stretchParameter: 2)
        let renderer = try FITSRenderer(device: device, viewport: canvas)
        let image = FITSImage.fromFloat32(pixels: [0.5], width: 1, height: 1)
        try renderer.setImage(image, revision: 1)
        let size = CGSize(width: 1, height: 1)
        let first = try renderer.renderOffscreen(viewSize: size, backingScale: 1)

        canvas.stretchParameter = 0.5
        canvas.colorMap = .plasma
        let second = try renderer.renderOffscreen(viewSize: size, backingScale: 1)
        let expected = ViewportRasterizer.renderViewport(
            try XCTUnwrap(renderer.displayImage),
            mapping: ViewMapping(transform: canvas.transform, viewSize: SIMD2(1, 1), backingScale: 1),
            width: 1, height: 1, stretch: .power,
            levels: RasterLevels(vmin: 0, vmax: 1), colorMap: .plasma, parameter: 0.5
        )
        XCTAssertNotEqual(first.bytes, second.bytes)
        for index in second.bytes.indices {
            XCTAssertLessThanOrEqual(abs(Int(second.bytes[index]) - Int(expected.bytes[index])), 1)
        }
    }

    func testRendererAcceptsSyntheticGaussianFITSFromDisk() throws {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sample.fits")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("sample.fits not present (run scripts/make_sample_fits.swift first)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let data = try Data(contentsOf: path)
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)

        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 0)
        XCTAssertEqual(renderer.texture?.width, 200)
        XCTAssertGreaterThan(renderer.vmax, renderer.vmin)
    }

    func testSetImageStoresImageForCursorReadback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let data = MakeFITS.uint8Image(naxis1: 2, naxis2: 2, pixels: [1, 2, 3, 4])
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 0)
        XCTAssertNotNil(renderer.image)
        XCTAssertEqual(renderer.image?.physicalValue(x: 1, y: 1), 4)
    }

    func testSetImageRetainsCallerRevisionInDisplayBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [7], width: 1, height: 1)
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 23)
        XCTAssertEqual(renderer.displayImage?.revision, 23)
        XCTAssertEqual(renderer.displayImage?.pixels, [7])
    }

    func testRendererAcceptsDisplayBuiltByCaller() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [1, 2], width: 2, height: 1)
        let display = DisplayImage(image: image, revision: 17)
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setDisplayImage(display, sourceImage: image)
        XCTAssertEqual(renderer.displayImage?.revision, 17)
        XCTAssertEqual(renderer.texture?.width, 2)
    }

    func testUploadingDisplayKeepsCallerLevels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let viewport = ImageViewState(vmin: 42, vmax: 99)
        let renderer = try FITSRenderer(device: device, viewport: viewport)
        let image = FITSImage.fromFloat32(pixels: [1, 2], width: 2, height: 1)
        try renderer.setDisplayImage(DisplayImage(image: image, revision: 1), sourceImage: image)
        XCTAssertEqual(viewport.vmin, 42)
        XCTAssertEqual(viewport.vmax, 99)
    }

    func testHistogramCDFTracksDisplayLevels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2, 3, 100], width: 5, height: 1)
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 1)
        renderer.vmin = 0
        renderer.vmax = 3
        renderer.updateCDFIfNeeded()
        XCTAssertEqual(renderer.currentCDF[0], 0.25)
        XCTAssertEqual(renderer.currentCDF[255], 1)

        renderer.vmin = 2
        renderer.vmax = 3
        renderer.updateCDFIfNeeded()
        XCTAssertEqual(renderer.currentCDF[0], 0.5)
        XCTAssertEqual(renderer.currentCDF[255], 1)
    }

    func testSetImagePopulatesTextureAndDefaultRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let pixels: [UInt8] = (1...100).map(UInt8.init)
        let data = MakeFITS.uint8Image(naxis1: 10, naxis2: 10, pixels: pixels)
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])

        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 0)

        XCTAssertEqual(renderer.texture?.width, 10)
        XCTAssertEqual(renderer.texture?.height, 10)
        XCTAssertGreaterThan(renderer.vmax, renderer.vmin)
    }

    func testOversizeImageUsesCPURasterFallback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 1, count: 20_000 * 10), width: 20_000, height: 10
        )
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 9)
        XCTAssertNil(renderer.texture)
        XCTAssertEqual(renderer.displayImage?.revision, 9)
        XCTAssertTrue(renderer.usesViewportRaster)
    }

    func testOffscreenMetalMatchesCPURasterAcrossStretchesMapsAndTransforms() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(
            pixels: [0, 1, 2, 3, 4, 5, .nan, .infinity, -.infinity, 2, 1, 0],
            width: 4, height: 3
        )
        let viewport = ImageViewState()
        let renderer = try FITSRenderer(device: device, viewport: viewport)
        try renderer.setImage(image, revision: 1)
        renderer.vmin = 0
        renderer.vmax = 5
        renderer.stretchParameter = 0.3
        let size = CGSize(width: 8, height: 6)
        let transforms = [
            ViewTransform(scale: 2, centre: SIMD2(1.5, 1)),
            ViewTransform(scale: 1, centre: SIMD2(1.5, 1)),
            ViewTransform(scale: 0.5, centre: SIMD2(1.5, 1)),
            ViewTransform(scale: 1.37, centre: SIMD2(0.72, 1.18)),
        ]
        for transform in transforms {
            renderer.transform = transform
            let mapping = ViewMapping(
                transform: transform, viewSize: SIMD2(8, 6), backingScale: 1
            )
            for stretch in ImageStretch.allCases {
                renderer.stretch = stretch
                for colorMap in ColorMap.allCases {
                    renderer.colorMap = colorMap
                    let gpu = try renderer.renderOffscreen(viewSize: size, backingScale: 1)
                    let cpu = ViewportRasterizer.renderViewport(
                        try XCTUnwrap(renderer.displayImage), mapping: mapping,
                        width: 8, height: 6, stretch: stretch,
                        levels: RasterLevels(vmin: 0, vmax: 5), colorMap: colorMap,
                        parameter: 0.3
                    )
                    for i in cpu.bytes.indices {
                        let error = abs(Int(gpu.bytes[i]) - Int(cpu.bytes[i]))
                        XCTAssertLessThanOrEqual(error, stretch == .linear ? 0 : 1,
                                                 "\(stretch) \(colorMap) \(transform) byte \(i)")
                    }
                }
            }
        }
    }

    func testOversizeFallbackActuallyDrawsViewport() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 1, count: 20_000 * 10), width: 20_000, height: 10
        )
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 1)
        renderer.vmin = 0
        renderer.vmax = 1
        renderer.transform = ViewTransform(scale: 1, centre: SIMD2(9_999.5, 4.5))
        let gpu = try renderer.renderOffscreen(viewSize: CGSize(width: 8, height: 8), backingScale: 1)
        XCTAssertEqual(gpu.pixel(x: 4, y: 4), RGBA8(r: 255, g: 255, b: 255))
    }

    func testRetinaDeviceCentresMatchCPURaster() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2, 3], width: 2, height: 2)
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 1)
        renderer.vmin = 0
        renderer.vmax = 3
        renderer.colorMap = .plasma
        let transform = ViewTransform(scale: 1.37, centre: SIMD2(0.45, 0.53))
        renderer.transform = transform
        let gpu = try renderer.renderOffscreen(viewSize: CGSize(width: 5, height: 5), backingScale: 2)
        let cpu = ViewportRasterizer.renderViewport(
            try XCTUnwrap(renderer.displayImage),
            mapping: ViewMapping(transform: transform, viewSize: SIMD2(5, 5), backingScale: 2),
            width: 10, height: 10, stretch: .linear,
            levels: RasterLevels(vmin: 0, vmax: 3), colorMap: .plasma
        )
        XCTAssertEqual(gpu.bytes, cpu.bytes)
    }

    func testResizePreservesUserZoom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let data = MakeFITS.uint8Image(naxis1: 10, naxis2: 10, pixels: [UInt8](repeating: 1, count: 100))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        try renderer.setImage(image, revision: 0)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 150), device: device)
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        let fittedScale = renderer.transform.scale
        renderer.transform.scale = fittedScale * 2
        renderer.transform.centre += SIMD2(3, -4)
        let pannedCentre = renderer.transform.centre
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 150)
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        XCTAssertEqual(renderer.transform.scale, fittedScale * 2, accuracy: 1e-12)
        XCTAssertEqual(renderer.transform.centre, pannedCentre)
    }

    func testNewDisplayRevisionPreservesUserZoom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let data = MakeFITS.uint8Image(naxis1: 10, naxis2: 10,
                                       pixels: [UInt8](repeating: 1, count: 100))
        let image = try FITSImage(hdu: FITSFile(data: data).hdus[0])
        let renderer = try FITSRenderer(device: device, viewport: ImageViewState())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 150), device: device)
        try renderer.setImage(image, revision: 0)
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        renderer.transform = ViewTransform(scale: 30, centre: SIMD2(3, 4))

        try renderer.setImage(image, revision: 1)

        XCTAssertEqual(renderer.transform, ViewTransform(scale: 30, centre: SIMD2(3, 4)))
    }

}

enum MakeFITS {
    static func uint8Image(naxis1: Int, naxis2: Int, pixels: [UInt8]) -> Data {
        var cards = [String]()
        cards.append(pad("SIMPLE  =                    T"))
        cards.append(pad("BITPIX  =                    8"))
        cards.append(pad("NAXIS   =                    2"))
        cards.append(pad("NAXIS1  = \(String(format: "%20d", naxis1))"))
        cards.append(pad("NAXIS2  = \(String(format: "%20d", naxis2))"))
        cards.append(pad("END"))
        var header = cards.joined()
        let block = 2880
        if header.count % block != 0 {
            header += String(repeating: " ", count: block - header.count % block)
        }
        var out = Data(header.utf8)
        out.append(Data(pixels))
        if pixels.count % block != 0 {
            out.append(Data(repeating: 0, count: block - pixels.count % block))
        }
        return out
    }

    private static func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
