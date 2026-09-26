import XCTest
import Metal
import MetalKit
import simd
import FITSCore
import FITSRaster
import TheiaKit
@testable import FITSRender

final class FITSRendererTests: XCTestCase {
    func testInitCompilesShadersAndCreatesPipeline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
        XCTAssertNil(renderer.texture)
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

        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
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
        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
        try renderer.setImage(image, revision: 0)
        XCTAssertNotNil(renderer.image)
        XCTAssertEqual(renderer.image?.physicalValue(x: 1, y: 1), 4)
    }

    func testSetImageRetainsCallerRevisionInDisplayBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [7], width: 1, height: 1)
        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
        try renderer.setImage(image, revision: 23)
        XCTAssertEqual(renderer.displayImage?.revision, 23)
        XCTAssertEqual(renderer.displayImage?.pixels, [7])
    }

    func testHistogramCDFTracksDisplayLevels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2, 3, 100], width: 5, height: 1)
        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
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

        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
        try renderer.setImage(image, revision: 0)

        XCTAssertEqual(renderer.texture?.width, 10)
        XCTAssertEqual(renderer.texture?.height, 10)
        XCTAssertGreaterThan(renderer.vmax, renderer.vmin)
    }

    func testResizePreservesUserZoom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let data = MakeFITS.uint8Image(naxis1: 10, naxis2: 10, pixels: [UInt8](repeating: 1, count: 100))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let renderer = try FITSRenderer(device: device, viewport: ViewportObservable())
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

    func testMetalProjectionPlacesTexelCentreOnMappedImagePoint() {
        let transform = ViewTransform(scale: 6, centre: SIMD2(0.75, 0.25))
        let viewSize = SIMD2(20.0, 20.0)
        let mapping = ViewMapping(transform: transform, viewSize: viewSize, backingScale: 1)
        let matrix = FITSRenderer.modelViewProjection(
            imageSize: SIMD2(2.0, 2.0), viewSize: viewSize, transform: transform
        )
        let clip = matrix * SIMD4<Float>(0.25, 0.25, 0, 1)
        let metalViewYUp = SIMD2(Double((clip.x + 1) * 10), Double((clip.y + 1) * 10))
        let mapped = mapping.imageToViewYUp(SIMD2(0.0, 0.0))
        XCTAssertEqual(metalViewYUp.x, mapped.x, accuracy: 1e-6)
        XCTAssertEqual(metalViewYUp.y, mapped.y, accuracy: 1e-6)
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
