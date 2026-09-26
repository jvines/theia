import XCTest
@testable import FITSCore

final class FITSImageTests: XCTestCase {
    func testPhysicalMinMaxSkipsUndefinedAndNonFinitePixels() {
        let image = FITSImage.fromFloat32(
            pixels: [.nan, 7, -.infinity, -3, .infinity, 2], width: 3, height: 2
        )
        let range = image.physicalMinMax()
        XCTAssertEqual(range?.min, -3)
        XCTAssertEqual(range?.max, 7)
    }

    func testNormalizedFloat32ProducesRowMajorBuffer() throws {
        let pixels: [UInt8] = [1, 2, 3, 4, 5, 6]
        let data = makeFITS(bitpix: 8, naxis1: 3, naxis2: 2, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let buf = image.normalizedFloat32()
        XCTAssertEqual(buf.count, 6)
        XCTAssertEqual(buf, [1, 2, 3, 4, 5, 6])
    }

    func testNormalizedFloat32PreservesNaNForBLANK() throws {
        let pixels: [UInt8] = [0x00, 0x07, 0x80, 0x00]
        let data = makeFITS(
            bitpix: 16, naxis1: 2, naxis2: 1, pixelBytes: Data(pixels),
            extraCards: ["BLANK   =               -32768"]
        )
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let buf = image.normalizedFloat32()
        XCTAssertEqual(buf[0], 7)
        XCTAssertTrue(buf[1].isNaN)
    }

    func testIntegerBLANKBecomesNaN() throws {
        // int16 pixels: 0x0000 (=0, valid), 0x8000 (=-32768, BLANK sentinel)
        let pixels: [UInt8] = [0x00, 0x00, 0x80, 0x00]
        let data = makeFITS(
            bitpix: 16, naxis1: 2, naxis2: 1, pixelBytes: Data(pixels),
            extraCards: ["BLANK   =               -32768"]
        )
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 0.0)
        XCTAssertTrue(image.physicalValue(x: 1, y: 0).isNaN)
    }

    func testAppliesBSCALEAndBZEROScaling() throws {
        // int16 raw value 5, BSCALE=2.0, BZERO=10.0 → physical = 10 + 2*5 = 20
        let pixels: [UInt8] = [0x00, 0x05]
        let data = makeFITS(
            bitpix: 16, naxis1: 1, naxis2: 1, pixelBytes: Data(pixels),
            extraCards: [
                "BSCALE  =                  2.0",
                "BZERO   =                 10.0",
            ]
        )
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 20.0)
    }

    func testReadsInt32BigEndian() throws {
        // 0x12345678 big-endian → 305419896
        let pixels: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let data = makeFITS(bitpix: 32, naxis1: 1, naxis2: 1, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 305419896.0)
    }

    func testReadsFloat64BigEndian() throws {
        // 1.5 = 0x3FF8000000000000 IEEE-754 double
        let pixels: [UInt8] = [0x3F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let data = makeFITS(bitpix: -64, naxis1: 1, naxis2: 1, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 1.5)
    }

    func testReadsFloat32BigEndian() throws {
        // 1.5 = 0x3FC00000 IEEE-754 single precision
        let pixels: [UInt8] = [0x3F, 0xC0, 0x00, 0x00]
        let data = makeFITS(bitpix: -32, naxis1: 1, naxis2: 1, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])

        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 1.5)
    }

    func testReadsInt16BigEndianWithByteSwap() throws {
        // 2 cols × 1 row, big-endian: 0x0100 → 256, 0xFFFF → -1 (two's complement)
        let pixels: [UInt8] = [0x01, 0x00, 0xFF, 0xFF]
        let data = makeFITS(bitpix: 16, naxis1: 2, naxis2: 1, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])

        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 256.0)
        XCTAssertEqual(image.physicalValue(x: 1, y: 0), -1.0)
    }

    func testDefaultRangeReturnsZScale() throws {
        let pixels: [UInt8] = (1...100).map(UInt8.init)
        let data = makeFITS(bitpix: 8, naxis1: 10, naxis2: 10, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])
        let r = image.defaultRange(contrast: 1.0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.z1, 1, accuracy: 5)
        XCTAssertEqual(r!.z2, 100, accuracy: 5)
    }

    func testFromFloat32RoundTripsPixelValues() {
        let pixels: [Float] = [1, 2, 3, 4, 5, 6]
        let image = FITSImage.fromFloat32(pixels: pixels, width: 3, height: 2)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 1)
        XCTAssertEqual(image.physicalValue(x: 2, y: 0), 3)
        XCTAssertEqual(image.physicalValue(x: 1, y: 1), 5)
        XCTAssertEqual(image.physicalValue(x: 2, y: 1), 6)
    }

    func testFromFloat32PreservesNaN() {
        let pixels: [Float] = [1, .nan, 3]
        let image = FITSImage.fromFloat32(pixels: pixels, width: 3, height: 1)
        XCTAssertTrue(image.physicalValue(x: 1, y: 0).isNaN)
    }

    func testReadsUInt8ImageInRowMajorOrder() throws {
        // 3 columns (NAXIS1) × 2 rows (NAXIS2)
        //   row 0: 1, 2, 3
        //   row 1: 4, 5, 6
        let pixels: [UInt8] = [1, 2, 3, 4, 5, 6]
        let data = makeFITS(bitpix: 8, naxis1: 3, naxis2: 2, pixelBytes: Data(pixels))
        let file = try FITSFile(data: data)
        let image = try FITSImage(hdu: file.hdus[0])

        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 1.0)
        XCTAssertEqual(image.physicalValue(x: 1, y: 0), 2.0)
        XCTAssertEqual(image.physicalValue(x: 2, y: 0), 3.0)
        XCTAssertEqual(image.physicalValue(x: 0, y: 1), 4.0)
        XCTAssertEqual(image.physicalValue(x: 1, y: 1), 5.0)
        XCTAssertEqual(image.physicalValue(x: 2, y: 1), 6.0)
    }

    // MARK: - BUG-10: degenerate high-dimensional cubes must render

    func testOpensDegenerateNAXIS4Cube() throws {
        // CASA/WSClean [RA, Dec, Freq=1, Stokes=1] — must render as a 2D image
        // instead of "Nothing to render here".
        let data = makeFITSND(bitpix: -32, axes: [2, 2, 1, 1], pixelBytes: float32BE([1, 2, 3, 4]))
        let file = try FITSFile(data: data)
        XCTAssertEqual(file.firstImageHDUIndex, 0, "degenerate 4D cube should be pickable as an image")
        let img = try FITSImage(hdu: file.hdus[0])
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(img.height, 2)
        XCTAssertEqual(img.physicalValue(x: 0, y: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(img.physicalValue(x: 1, y: 1), 4, accuracy: 1e-6)
    }

    func testExtractsPlanesFromNAXIS4CubeWithDegenerateStokes() throws {
        // [RA, Dec, Freq=2, Stokes=1] — a real 2-plane cube with a degenerate axis.
        // Planes stack contiguously in row-major order.
        let data = makeFITSND(bitpix: -32, axes: [2, 2, 2, 1],
                              pixelBytes: float32BE([1, 2, 3, 4, 10, 20, 30, 40]))
        let file = try FITSFile(data: data)
        let p0 = try FITSImage(hdu: file.hdus[0], plane: 0)
        let p1 = try FITSImage(hdu: file.hdus[0], plane: 1)
        XCTAssertEqual(p0.physicalValue(x: 0, y: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(p1.physicalValue(x: 0, y: 0), 10, accuracy: 1e-6)
        XCTAssertEqual(p1.physicalValue(x: 1, y: 1), 40, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private func makeFITSND(bitpix: Int, axes: [Int], pixelBytes: Data) -> Data {
        var cards: [String] = [
            card("SIMPLE", boolValue: true),
            card("BITPIX", intValue: bitpix),
            card("NAXIS", intValue: axes.count),
        ]
        for (i, a) in axes.enumerated() {
            cards.append(card("NAXIS\(i + 1)", intValue: a))
        }
        cards.append(padTo80("END"))
        var header = cards.joined()
        if header.count % 2880 != 0 { header += String(repeating: " ", count: 2880 - header.count % 2880) }
        var out = Data(header.utf8)
        out.append(pixelBytes)
        if out.count % 2880 != 0 { out.append(Data(count: 2880 - out.count % 2880)) }
        return out
    }

    private func float32BE(_ values: [Float]) -> Data {
        var d = Data()
        for v in values {
            var be = v.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// Build a minimal valid FITS file in memory.
    func makeFITS(
        bitpix: Int,
        naxis1: Int,
        naxis2: Int,
        pixelBytes: Data,
        extraCards: [String] = []
    ) -> Data {
        var cards: [String] = [
            card("SIMPLE", boolValue: true),
            card("BITPIX", intValue: bitpix),
            card("NAXIS", intValue: 2),
            card("NAXIS1", intValue: naxis1),
            card("NAXIS2", intValue: naxis2),
        ]
        cards.append(contentsOf: extraCards.map { padTo80($0) })
        cards.append(padTo80("END"))

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

    func card(_ keyword: String, intValue: Int) -> String {
        let kw = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        return padTo80("\(kw)= \(String(format: "%20d", intValue))")
    }

    func card(_ keyword: String, boolValue: Bool) -> String {
        let kw = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        let v = boolValue ? "T" : "F"
        return padTo80("\(kw)= \(String(repeating: " ", count: 19))\(v)")
    }

    func padTo80(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
