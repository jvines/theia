import XCTest
@testable import FITSCore

final class FITSFileKindTests: XCTestCase {
    func testFirstImageHDUIndexReturnsZeroForSinglePrimaryImage() throws {
        let data = buildSinglePrimaryImage()
        let file = try FITSFile(data: data)
        XCTAssertEqual(file.firstImageHDUIndex, 0)
    }

    func testFirstImageHDUIndexSkipsEmptyPrimary() throws {
        // Use the committed multi_hdu fixture (primary NAXIS=0 + IMAGE ext 8×8)
        guard let url = Bundle.module.url(
            forResource: "multi_hdu",
            withExtension: "fits",
            subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("fixture not found")
        }
        let data = try Data(contentsOf: url)
        let file = try FITSFile(data: data)
        XCTAssertEqual(file.firstImageHDUIndex, 1)
    }

    func testFirstImageHDUIndexReturnsNilWhenNoImage() throws {
        let data = buildPrimaryWithNAXIS0()
        let file = try FITSFile(data: data)
        XCTAssertNil(file.firstImageHDUIndex)
    }

    func testHDUKindRecognizesBINTABLE() throws {
        // Degenerate BINTABLE: NAXIS=2, NAXIS1=0, NAXIS2=0 → no data, parser-safe.
        let data = buildPrimaryThenDegenerateBintable()
        let file = try FITSFile(data: data)
        let table = file.hdus[1]
        XCTAssertTrue(table.isTable)
        XCTAssertFalse(table.isImage)
        XCTAssertEqual(table.xtension, "BINTABLE")
    }

    // MARK: - Builders

    private func buildSinglePrimaryImage() -> Data {
        var out = headerBlock([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                    2",
            "NAXIS2  =                    1",
            "END",
        ])
        out.append(Data([1, 2]))
        return padToBlock(out)
    }

    private func buildPrimaryWithNAXIS0() -> Data {
        headerBlock([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "END",
        ])
    }

    private func buildPrimaryThenDegenerateBintable() -> Data {
        var out = headerBlock([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "EXTEND  =                    T",
            "END",
        ])
        let ext = headerBlock([
            "XTENSION= 'BINTABLE'         ",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                    0",
            "NAXIS2  =                    0",
            "PCOUNT  =                    0",
            "GCOUNT  =                    1",
            "TFIELDS =                    0",
            "END",
        ])
        out.append(ext)
        return out
    }

    // BUG-17: Random Groups FITS (NAXIS1=0, GROUPS=T) must open; the data unit is
    // |BITPIX|/8 × GCOUNT × (PCOUNT + product of NAXIS2..NAXISm).
    func testOpensRandomGroupsFITS() throws {
        var out = headerBlock([
            "SIMPLE  =                    T",
            "BITPIX  =                  -32",
            "NAXIS   =                    2",
            "NAXIS1  =                    0",
            "NAXIS2  =                    4",
            "GROUPS  =                    T",
            "PCOUNT  =                    3",
            "GCOUNT  =                    2",
            "END",
        ])
        // data unit = 4 bytes × GCOUNT 2 × (PCOUNT 3 + product 4) = 56 bytes.
        // 0xFF bytes force the old failure path (parsed as a non-ASCII next header).
        out.append(Data(repeating: 0xFF, count: 56))
        let data = padToBlock(out)
        XCTAssertNoThrow(try FITSFile(data: data))
        let file = try FITSFile(data: data)
        XCTAssertEqual(file.hdus.count, 1)
        XCTAssertEqual(file.hdus[0].header.dataLengthBytes(), 56)
    }

    func testDegenerateEmptyArrayStillReportsZeroLength() throws {
        // A genuinely empty array (NAXIS1=0, no GROUPS) must still be 0 bytes.
        let file = try FITSFile(data: buildPrimaryThenDegenerateBintable())
        XCTAssertEqual(file.hdus[1].header.dataLengthBytes(), 0)
    }

    private func headerBlock(_ cards: [String]) -> Data {
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let block = 2880
        if s.count % block != 0 {
            s += String(repeating: " ", count: block - s.count % block)
        }
        return Data(s.utf8)
    }

    private func padToBlock(_ data: Data) -> Data {
        var out = data
        let r = out.count % 2880
        if r != 0 { out.append(Data(repeating: 0, count: 2880 - r)) }
        return out
    }
}
