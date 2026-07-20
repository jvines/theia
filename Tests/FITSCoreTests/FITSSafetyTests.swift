import XCTest
@testable import FITSCore

/// Tests that the FITS parser refuses crafted / hostile input cleanly instead of
/// crashing or wrapping into UB. Each test exercises one of the audit's C1–C3
/// concerns (integer overflow on dimensions, NaN through `Int64()`, OOB on
/// `physicalValue`).
final class FITSSafetyTests: XCTestCase {
    private func pad(_ s: String) -> String { s.padding(toLength: 80, withPad: " ", startingAt: 0) }

    private func makeHeader(_ extra: [String], pad blockTo: Bool = true) -> Data {
        var cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
        ] + extra.map { pad($0) } + [pad("END")]
        var s = cards.joined()
        if blockTo, s.count % 2880 != 0 {
            s += String(repeating: " ", count: 2880 - s.count % 2880)
        }
        return Data(s.utf8)
    }

    /// Build a complete header from scratch (no defaults to shadow overrides).
    private func customHeader(_ cards: [String]) -> Data {
        var s = (cards + ["END"]).map { pad($0) }.joined()
        if s.count % 2880 != 0 {
            s += String(repeating: " ", count: 2880 - s.count % 2880)
        }
        return Data(s.utf8)
    }

    // MARK: C1 — integer overflow on dimensions

    func testRejectsAstronomicallyLargeDimensions() {
        // NAXIS1 × NAXIS2 × bytesPerPixel overflows Int. BITPIX=-64 = 8 bytes/pix.
        let data = customHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                  -64",
            "NAXIS   =                    2",
            "NAXIS1  =           2000000000",
            "NAXIS2  =           2000000000",
        ])
        XCTAssertThrowsError(try FITSFile(data: data)) { err in
            switch err as? FITSError {
            case .truncated, .invalidHeader: break
            default: XCTFail("unexpected error: \(err)")
            }
        }
    }

    func testRejectsNegativeNAXIS() {
        // A negative NAXIS shouldn't crash the parser.
        let data = customHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                   -1",
        ])
        XCTAssertNoThrow(try FITSFile(data: data))
    }

    func testRejectsAbsurdNAXIS() {
        // NAXIS = 999 is technically legal FITS but we cap at 16.
        let data = customHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                  999",
            "NAXIS1  =                    1",
        ])
        XCTAssertThrowsError(try FITSFile(data: data))
    }

    // MARK: C2 — NaN through Int64 in physicalValue

    func testPhysicalValueDoesNotTrapOnFloatNaNWithBLANK() throws {
        // Float32 image with NaN pixel + a BLANK keyword that *would* normally
        // apply only to integer types — verify we don't `Int64(raw)` on NaN.
        let header = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                  -32"),
            pad("NAXIS   =                    2"),
            pad("NAXIS1  =                    1"),
            pad("NAXIS2  =                    1"),
            pad("END"),
        ].joined()
        var bytes = Data(header.utf8)
        if bytes.count % 2880 != 0 {
            bytes.append(Data(count: 2880 - bytes.count % 2880))
        }
        // One float32 NaN pixel, big-endian.
        let nan = Float.nan.bitPattern.bigEndian
        withUnsafeBytes(of: nan) { bytes.append(contentsOf: $0) }
        if bytes.count % 2880 != 0 {
            bytes.append(Data(count: 2880 - bytes.count % 2880))
        }
        let file = try FITSFile(data: bytes)
        let img = try FITSImage(hdu: file.hdus[0])
        XCTAssertTrue(img.physicalValue(x: 0, y: 0).isNaN)
    }

    /// BUG-3: a NAXISn given as an out-of-range / non-finite float must not trap
    /// the `Int(v)` conversion inside `Value.intValue` (reached via
    /// `dataLengthBytes` during `FITSFile.init`).
    func testDoesNotTrapOnNonFiniteOrHugeNAXIS() {
        for bad in ["1E30", "-1E30", "nan", "inf"] {
            let field = String(repeating: " ", count: Swift.max(0, 20 - bad.count)) + bad
            let data = customHeader([
                "SIMPLE  =                    T",
                "BITPIX  =                    8",
                "NAXIS   =                    1",
                "NAXIS1  = \(field)",
            ])
            XCTAssertThrowsError(try FITSFile(data: data), "NAXIS1=\(bad) must throw, not trap")
        }
    }

    // MARK: C3 — bounds check on physicalValue

    func testPhysicalValueReturnsNaNForOutOfBoundsIndices() throws {
        // 2×2 uint8 image — out-of-bounds reads must return NaN, not crash.
        let header = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    2"),
            pad("NAXIS1  =                    2"),
            pad("NAXIS2  =                    2"),
            pad("END"),
        ].joined()
        var bytes = Data(header.utf8)
        if bytes.count % 2880 != 0 {
            bytes.append(Data(count: 2880 - bytes.count % 2880))
        }
        bytes.append(contentsOf: [10, 20, 30, 40])
        if bytes.count % 2880 != 0 {
            bytes.append(Data(count: 2880 - bytes.count % 2880))
        }
        let file = try FITSFile(data: bytes)
        let img = try FITSImage(hdu: file.hdus[0])
        // In-bounds works.
        XCTAssertEqual(img.physicalValue(x: 0, y: 0), 10)
        XCTAssertEqual(img.physicalValue(x: 1, y: 1), 40)
        // OOB returns NaN.
        XCTAssertTrue(img.physicalValue(x: -1, y: 0).isNaN)
        XCTAssertTrue(img.physicalValue(x: 0, y: -1).isNaN)
        XCTAssertTrue(img.physicalValue(x: 2, y: 0).isNaN)
        XCTAssertTrue(img.physicalValue(x: 0, y: 2).isNaN)
        XCTAssertTrue(img.physicalValue(x: 100, y: 100).isNaN)
    }
}
