import XCTest
@testable import FITSCore

final class FITSHDUExtensionsTests: XCTestCase {
    func testBitpixLabelMapsKnownTypes() throws {
        try XCTAssertEqual(makeHDU(bitpix: 8).bitpixLabel, "uint8")
        try XCTAssertEqual(makeHDU(bitpix: 16).bitpixLabel, "int16")
        try XCTAssertEqual(makeHDU(bitpix: 32).bitpixLabel, "int32")
        try XCTAssertEqual(makeHDU(bitpix: -32).bitpixLabel, "float32")
        try XCTAssertEqual(makeHDU(bitpix: -64).bitpixLabel, "float64")
    }

    func testAxesIsEmptyForNAXISZero() throws {
        // Primary HDU with NAXIS=0 (stub) must NOT trap when accessing .axes.
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        let file = try FITSFile(data: Data(header.utf8))
        XCTAssertEqual(file.hdus[0].axes, [])
        XCTAssertEqual(file.hdus[0].shapeDescription, "no data")
    }

    func testCardValueDisplayString() {
        XCTAssertEqual(FITSHeader.Value.integer(42).displayString, "42")
        XCTAssertEqual(FITSHeader.Value.float(3.14).displayString, "3.14")
        XCTAssertEqual(FITSHeader.Value.bool(true).displayString, "T")
        XCTAssertEqual(FITSHeader.Value.bool(false).displayString, "F")
        XCTAssertEqual(FITSHeader.Value.string("Tycho").displayString, "Tycho")
    }

    private func makeHDU(bitpix: Int) throws -> FITSHDU {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  = \(String(format: "%20d", bitpix))"),
            pad("NAXIS   =                    2"),
            pad("NAXIS1  =                    4"),
            pad("NAXIS2  =                    1"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        let bytesPerPix = max(abs(bitpix) / 8, 1)
        var data = Data(header.utf8)
        data.append(Data(repeating: 0, count: 4 * bytesPerPix))
        let used = 4 * bytesPerPix
        if used % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - used % 2880))
        }
        let file = try FITSFile(data: data)
        return file.hdus[0]
    }

    private func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
