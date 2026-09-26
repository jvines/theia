import XCTest
import AppKit
import FITSCore
@testable import FITSRender

final class ImageExportTests: XCTestCase {
    func testRenderProducesRGBABytesMatchingLinearStretch() throws {
        let data = MakeFITS.uint8Image(naxis1: 2, naxis2: 1, pixels: [0, 100])
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let bytes = ImageExport.render(image, stretch: .linear, vmin: 0, vmax: 100)
        XCTAssertEqual(bytes.count, 2 * 1 * 4)
        // pixel 0
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[3], 255)
        // pixel 1
        XCTAssertEqual(bytes[4], 255)
        XCTAssertEqual(bytes[7], 255)
    }

    func testWritePNGProducesValidFile() throws {
        let data = MakeFITS.uint8Image(naxis1: 2, naxis2: 2, pixels: [0, 100, 200, 255])
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fits_export_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ImageExport.writeImage(image, stretch: .linear, vmin: 0, vmax: 255, format: .png, to: tmp)
        let read = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(read.count, 8)
        XCTAssertEqual(Array(read.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testRenderNaNBecomesBlack() throws {
        let pixels: [UInt8] = [0x00, 0x07, 0x80, 0x00]  // int16: 7 and -32768 (BLANK)
        let data = MakeFITS.int16Image(
            naxis1: 2,
            naxis2: 1,
            pixelBytes: Data(pixels),
            extraCards: ["BLANK   =               -32768"]
        )
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let bytes = ImageExport.render(image, stretch: .linear, vmin: 0, vmax: 10)
        // pixel 1 (BLANK): r=g=b=0, a=255
        XCTAssertEqual(bytes[4], 0)
        XCTAssertEqual(bytes[5], 0)
        XCTAssertEqual(bytes[6], 0)
        XCTAssertEqual(bytes[7], 255)
    }

    func testRenderUsesSelectedMapAndFITSPixelOrientation() {
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2, 3], width: 2, height: 2)
        let bytes = ImageExport.render(
            image, stretch: .linear, vmin: 0, vmax: 3, colorMap: .invertedGray
        )
        // Encoded row zero is the image's upper row; FITS (1,1) is lower left.
        XCTAssertEqual(Array(bytes[0..<4]), [85, 85, 85, 255])
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0, 255])
        XCTAssertEqual(Array(bytes[8..<12]), [255, 255, 255, 255])
    }

    func testPNGAndTIFFDecodeAtNativeResolution() throws {
        let image = FITSImage.fromFloat32(pixels: [0, 1, 2, 3], width: 2, height: 2)
        for format in [ExportFormat.png, .tiff] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("theia-export-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: url) }
            try ImageExport.writeImage(
                image, stretch: .linear, vmin: 0, vmax: 3, format: format, to: url
            )
            let data = try Data(contentsOf: url)
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(decoded.pixelsWide, 2)
            XCTAssertEqual(decoded.pixelsHigh, 2)
            let topLeft = try XCTUnwrap(decoded.colorAt(x: 0, y: 0))
            let bottomLeft = try XCTUnwrap(decoded.colorAt(x: 0, y: 1))
            XCTAssertEqual(topLeft.redComponent, 2.0 / 3.0, accuracy: 0.01)
            XCTAssertEqual(bottomLeft.redComponent, 0, accuracy: 0.01)
        }
    }
}

extension MakeFITS {
    static func int16Image(naxis1: Int, naxis2: Int, pixelBytes: Data, extraCards: [String]) -> Data {
        var cards = [String]()
        cards.append(pad("SIMPLE  =                    T"))
        cards.append(pad("BITPIX  =                   16"))
        cards.append(pad("NAXIS   =                    2"))
        cards.append(pad("NAXIS1  = \(String(format: "%20d", naxis1))"))
        cards.append(pad("NAXIS2  = \(String(format: "%20d", naxis2))"))
        for c in extraCards { cards.append(pad(c)) }
        cards.append(pad("END"))
        var header = cards.joined()
        let block = 2880
        if header.count % block != 0 {
            header += String(repeating: " ", count: block - header.count % block)
        }
        var out = Data(header.utf8)
        out.append(pixelBytes)
        if pixelBytes.count % block != 0 {
            out.append(Data(repeating: 0, count: block - pixelBytes.count % block))
        }
        return out
    }

    private static func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
