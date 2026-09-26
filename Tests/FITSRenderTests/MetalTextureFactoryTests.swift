import XCTest
import Metal
import FITSCore
import FITSRaster
@testable import FITSRender

final class MetalTextureFactoryTests: XCTestCase {
    func testTextureContentsRoundTripPhysicalValues() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let pixels: [UInt8] = [10, 20, 30, 40, 50, 60]
        let data = makeFITS(bitpix: 8, naxis1: 3, naxis2: 2, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let texture = try MetalTextureFactory.makeTexture(
            from: DisplayImage(image: image, revision: 0), device: device
        )

        var readback = [Float](repeating: 0, count: 6)
        let region = MTLRegionMake2D(0, 0, 3, 2)
        let bytesPerRow = 3 * MemoryLayout<Float>.size
        readback.withUnsafeMutableBytes { buf in
            texture.getBytes(
                buf.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        XCTAssertEqual(readback, [10, 20, 30, 40, 50, 60])
    }

    func testCreatesTextureWithImageDimensionsAndR32FloatFormat() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let pixels: [UInt8] = [1, 2, 3, 4]
        let data = makeFITS(bitpix: 8, naxis1: 2, naxis2: 2, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])

        let texture = try MetalTextureFactory.makeTexture(
            from: DisplayImage(image: image, revision: 0), device: device
        )
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.pixelFormat, .r32Float)
    }

    func testUploadsDisplayImagePixelsIncludingNaN() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = FITSImage.fromFloat32(pixels: [1, .nan], width: 2, height: 1)
        let display = DisplayImage(image: image, revision: 14)
        let texture = try MetalTextureFactory.makeTexture(from: display, device: device)
        var readback = [Float](repeating: 0, count: 2)
        readback.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!, bytesPerRow: 2 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0
            )
        }
        XCTAssertEqual(readback[0], 1)
        XCTAssertTrue(readback[1].isNaN)
    }

    // MARK: - Test FITS builder (duplicated from FITSCoreTests since SwiftPM
    // doesn't share test helpers across targets; kept minimal).

    func makeFITS(bitpix: Int, naxis1: Int, naxis2: Int, pixelBytes: Data) -> Data {
        var cards = [String]()
        cards.append(pad("SIMPLE  =                    T"))
        cards.append(pad("BITPIX  = \(String(format: "%20d", bitpix))"))
        cards.append(pad("NAXIS   =                    2"))
        cards.append(pad("NAXIS1  = \(String(format: "%20d", naxis1))"))
        cards.append(pad("NAXIS2  = \(String(format: "%20d", naxis2))"))
        cards.append(pad("END"))
        var header = cards.joined()
        let blockSize = 2880
        if header.count % blockSize != 0 {
            header += String(repeating: " ", count: blockSize - header.count % blockSize)
        }
        var out = Data(header.utf8)
        out.append(pixelBytes)
        if pixelBytes.count % blockSize != 0 {
            out.append(Data(repeating: 0, count: blockSize - pixelBytes.count % blockSize))
        }
        return out
    }

    private func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
