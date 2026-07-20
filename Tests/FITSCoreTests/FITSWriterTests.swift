import XCTest
@testable import FITSCore

final class FITSWriterTests: XCTestCase {
    func testRoundTripsFloat32Image() throws {
        let original = FITSImage.fromFloat32(pixels: [1, 2, 3, 4, 5, 6, 7, 8, 9],
                                             width: 3, height: 3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fitswriter-\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FITSWriter.write(original, to: tmp)

        // Re-read.
        let data = try Data(contentsOf: tmp)
        let restored = try FITSFile(data: data).hdus[0]
        XCTAssertEqual(restored.naxis, 2)
        XCTAssertEqual(restored.axes, [3, 3])
        let img = try FITSImage(hdu: restored)
        XCTAssertEqual(img.physicalValue(x: 0, y: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(img.physicalValue(x: 2, y: 2), 9, accuracy: 1e-6)
    }

    func testFileSizeIsBlockAligned() throws {
        let original = FITSImage.fromFloat32(pixels: [Float](repeating: 0, count: 100), width: 10, height: 10)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fitswriter-\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FITSWriter.write(original, to: tmp)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(size % 2880, 0, "FITS file size must be a multiple of 2880")
    }

    // MARK: - BUG-1: saving an integer image that contains a BLANK/undefined pixel

    /// Builds a minimal single-HDU integer FITS file carrying a `BLANK` card and
    /// the supplied big-endian raw pixel bytes.
    private func makeIntFITS(bitpix: Int, width: Int, height: Int, blank: Int, pixelBytes: [UInt8]) -> Data {
        func pad(_ s: String) -> String { s.padding(toLength: 80, withPad: " ", startingAt: 0) }
        func card(_ key: String, _ value: Int) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            let v = String(repeating: " ", count: max(0, 20 - String(value).count)) + String(value)
            return pad("\(k)= \(v)")
        }
        let cards = [
            pad("SIMPLE  =                    T"),
            card("BITPIX", bitpix),
            card("NAXIS", 2),
            card("NAXIS1", width),
            card("NAXIS2", height),
            card("BLANK", blank),
            pad("END"),
        ]
        var s = cards.joined()
        if s.count % 2880 != 0 { s += String(repeating: " ", count: 2880 - s.count % 2880) }
        var bytes = Data(s.utf8)
        bytes.append(contentsOf: pixelBytes)
        if bytes.count % 2880 != 0 { bytes.append(Data(count: 2880 - bytes.count % 2880)) }
        return bytes
    }

    /// Loads a 2×2 integer image whose pixel (1,0) is BLANK, writes it back out,
    /// and asserts the round-trip preserves both the good pixel and the blank
    /// (via a re-emitted BLANK card). Before the fix, `FITSWriter.write` traps
    /// with `SIGTRAP` on `Int16(nan)` / `Int32(nan)` / `UInt8(nan)`.
    private func assertBlankRoundTrips(
        bitpix: Int, blank: Int, blankBytes: [UInt8],
        goodValue: Int, goodBytes: [UInt8],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Row-major layout: (0,0)=good, (1,0)=BLANK, (0,1)=good, (1,1)=good.
        let pix = goodBytes + blankBytes + goodBytes + goodBytes
        let data = makeIntFITS(bitpix: bitpix, width: 2, height: 2, blank: blank, pixelBytes: pix)
        let img = try FITSImage(hdu: FITSFile(data: data).hdus[0])
        XCTAssertEqual(img.blank, Int64(blank), file: file, line: line)
        XCTAssertTrue(img.physicalValue(x: 1, y: 0).isNaN, "source blank pixel should read NaN", file: file, line: line)
        XCTAssertEqual(img.physicalValue(x: 0, y: 0), Double(goodValue), accuracy: 1e-9, file: file, line: line)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fitswriter-blank-\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FITSWriter.write(img, to: tmp)

        let restoredHDU = try FITSFile(data: Data(contentsOf: tmp)).hdus[0]
        XCTAssertEqual(restoredHDU.header["BLANK"]?.intValue, blank,
                       "BLANK card must survive the write so undefined pixels stay undefined",
                       file: file, line: line)
        let restored = try FITSImage(hdu: restoredHDU)
        XCTAssertTrue(restored.physicalValue(x: 1, y: 0).isNaN,
                      "blank pixel must round-trip as NaN", file: file, line: line)
        XCTAssertEqual(restored.physicalValue(x: 0, y: 0), Double(goodValue), accuracy: 1e-9, file: file, line: line)
    }

    func testWritesInt16ImageWithBlankPixel() throws {
        // BLANK = -32768, blank pixel bytes 0x80 0x00; good value 100 = 0x00 0x64.
        try assertBlankRoundTrips(bitpix: 16, blank: -32768, blankBytes: [0x80, 0x00],
                                  goodValue: 100, goodBytes: [0x00, 0x64])
    }

    func testWritesInt32ImageWithBlankPixel() throws {
        // BLANK = Int32.min, bytes 0x80 00 00 00; good value 70000 = 0x00 01 11 70.
        try assertBlankRoundTrips(bitpix: 32, blank: -2147483648, blankBytes: [0x80, 0x00, 0x00, 0x00],
                                  goodValue: 70000, goodBytes: [0x00, 0x01, 0x11, 0x70])
    }

    func testWritesUInt8ImageWithBlankPixel() throws {
        // BITPIX=8 (unsigned): BLANK = 200; good value 50.
        try assertBlankRoundTrips(bitpix: 8, blank: 200, blankBytes: [200],
                                  goodValue: 50, goodBytes: [50])
    }
}
