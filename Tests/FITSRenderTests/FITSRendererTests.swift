import XCTest
import Metal
import FITSCore
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
        try renderer.setImage(image)
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
        try renderer.setImage(image)
        XCTAssertNotNil(renderer.image)
        XCTAssertEqual(renderer.image?.physicalValue(x: 1, y: 1), 4)
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
        try renderer.setImage(image)

        XCTAssertEqual(renderer.texture?.width, 10)
        XCTAssertEqual(renderer.texture?.height, 10)
        XCTAssertGreaterThan(renderer.vmax, renderer.vmin)
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
