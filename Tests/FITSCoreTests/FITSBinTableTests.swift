import XCTest
@testable import FITSCore

final class FITSBinTableTests: XCTestCase {
    func testParsesIntegerAndFloatColumnsFromSyntheticBINTABLE() throws {
        // 2 columns: id (1J = int32), mag (1E = float32). 3 rows.
        // bytes per row = 4 + 4 = 8. Total data = 24 bytes.
        let header = headerBlock([
            "XTENSION= 'BINTABLE'           ",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                    8",
            "NAXIS2  =                    3",
            "PCOUNT  =                    0",
            "GCOUNT  =                    1",
            "TFIELDS =                    2",
            "TTYPE1  = 'id'                ",
            "TFORM1  = '1J'                ",
            "TTYPE2  = 'mag'               ",
            "TFORM2  = '1E'                ",
            "TUNIT2  = 'mag'               ",
            "END",
        ])
        var data = Data()
        // Row 0: id=42, mag=15.5
        appendInt32BE(&data, 42)
        appendFloat32BE(&data, 15.5)
        // Row 1: id=-7, mag=20.3
        appendInt32BE(&data, -7)
        appendFloat32BE(&data, 20.3)
        // Row 2: id=1000, mag=12.0
        appendInt32BE(&data, 1000)
        appendFloat32BE(&data, 12.0)
        // pad to 2880
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }

        let primary = primaryBlock()
        let file = try FITSFile(data: primary + header + data)
        let table = try XCTUnwrap(FITSBinTable(hdu: file.hdus[1]))

        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(table.columns.count, 2)
        XCTAssertEqual(table.columns[0].name, "id")
        XCTAssertEqual(table.columns[0].type, .int32)
        XCTAssertEqual(table.columns[1].name, "mag")
        XCTAssertEqual(table.columns[1].type, .float32)
        XCTAssertEqual(table.columns[1].unit, "mag")

        XCTAssertEqual(table.displayValue(row: 0, column: 0), "42")
        XCTAssertEqual(table.displayValue(row: 0, column: 1), "15.5")
        XCTAssertEqual(table.displayValue(row: 1, column: 0), "-7")
        XCTAssertEqual(table.displayValue(row: 2, column: 0), "1000")
        XCTAssertEqual(table.displayValue(row: 2, column: 1), "12")
    }

    func testParsesCharacterAndArrayColumns() throws {
        // 2 columns: name (8A = 8 chars), vec (3E = 3 floats). 2 rows.
        // bytes per row = 8 + 12 = 20. Total = 40 bytes.
        let header = headerBlock([
            "XTENSION= 'BINTABLE'           ",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                   20",
            "NAXIS2  =                    2",
            "PCOUNT  =                    0",
            "GCOUNT  =                    1",
            "TFIELDS =                    2",
            "TTYPE1  = 'name'              ",
            "TFORM1  = '8A'                ",
            "TTYPE2  = 'vec'               ",
            "TFORM2  = '3E'                ",
            "END",
        ])
        var data = Data()
        data.append("Star A  ".data(using: .ascii)!)
        appendFloat32BE(&data, 1.0); appendFloat32BE(&data, 2.0); appendFloat32BE(&data, 3.0)
        data.append("Galaxy B".data(using: .ascii)!)
        appendFloat32BE(&data, 4.0); appendFloat32BE(&data, 5.0); appendFloat32BE(&data, 6.0)
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }
        let file = try FITSFile(data: primaryBlock() + header + data)
        let table = try XCTUnwrap(FITSBinTable(hdu: file.hdus[1]))

        XCTAssertEqual(table.columns[0].type, .character)
        XCTAssertEqual(table.columns[0].repeatCount, 8)
        XCTAssertEqual(table.displayValue(row: 0, column: 0), "Star A")
        XCTAssertEqual(table.displayValue(row: 1, column: 0), "Galaxy B")

        XCTAssertEqual(table.columns[1].repeatCount, 3)
        XCTAssertEqual(table.displayValue(row: 0, column: 1), "[1, 2, 3]")
        XCTAssertEqual(table.displayValue(row: 1, column: 1), "[4, 5, 6]")
    }

    func testReturnsNilForNonBinTableHDU() throws {
        let primary = primaryBlock()
        let file = try FITSFile(data: primary)
        XCTAssertNil(FITSBinTable(hdu: file.hdus[0]))
    }

    // MARK: - BUG-13: column geometry exceeding the row must not trap displayValue

    /// Two 1J (4-byte) columns are declared but NAXIS1=4, so column 1's byte
    /// extent (offset 4..8) runs off the end of the 4-byte row/data. The unguarded
    /// `base + read` traps; after the fix the overrunning cell returns "" while the
    /// in-bounds cell still renders.
    func testBinTableColumnBeyondRowDoesNotTrap() throws {
        let header = headerBlock([
            "XTENSION= 'BINTABLE'           ",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                    4",   // room for only ONE 1J column
            "NAXIS2  =                    1",
            "PCOUNT  =                    0",
            "GCOUNT  =                    1",
            "TFIELDS =                    2",
            "TTYPE1  = 'a'                 ",
            "TFORM1  = '1J'                ",
            "TTYPE2  = 'b'                 ",
            "TFORM2  = '1J'                ",   // byteOffset 4, past NAXIS1=4
            "END",
        ])
        var data = Data()
        appendInt32BE(&data, 123)   // 4 bytes = one row
        if data.count % 2880 != 0 { data.append(Data(repeating: 0, count: 2880 - data.count % 2880)) }
        let file = try FITSFile(data: primaryBlock() + header + data)
        let table = try XCTUnwrap(FITSBinTable(hdu: file.hdus[1]))
        XCTAssertEqual(table.displayValue(row: 0, column: 0), "123")   // in-bounds still works
        XCTAssertEqual(table.displayValue(row: 0, column: 1), "")      // overrun → safe empty
    }

    // MARK: - Helpers

    private func primaryBlock() -> Data {
        headerBlock([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "EXTEND  =                    T",
            "END",
        ])
    }

    private func headerBlock(_ cards: [String]) -> Data {
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        if s.count % 2880 != 0 {
            s += String(repeating: " ", count: 2880 - s.count % 2880)
        }
        return Data(s.utf8)
    }

    private func appendInt32BE(_ data: inout Data, _ v: Int32) {
        let u = UInt32(bitPattern: v).bigEndian
        withUnsafeBytes(of: u) { data.append(contentsOf: $0) }
    }

    private func appendFloat32BE(_ data: inout Data, _ v: Float) {
        let u = v.bitPattern.bigEndian
        withUnsafeBytes(of: u) { data.append(contentsOf: $0) }
    }
}
